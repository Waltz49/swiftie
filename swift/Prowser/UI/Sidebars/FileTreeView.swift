import AppKit
import SwiftUI

/// Lazy file system tree for the left sidebar. Port of `files/file_tree_handler.py`.
struct FileTreeView: NSViewRepresentable {
    @Environment(AppState.self) private var appState

    func makeCoordinator() -> Coordinator {
        Coordinator(appState: appState)
    }

    func makeNSView(context: Context) -> NSView {
        let tabStop = MainWindowTabFocusStopView(frame: .zero)
        tabStop.role = .tree
        tabStop.appState = appState
        appState.mainWindowTreeTabStop = tabStop

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        let outline = FileTreeOutlineView()
        outline.headerView = nil
        outline.delegate = context.coordinator
        outline.dataSource = context.coordinator
        outline.coordinator = context.coordinator
        outline.appState = appState
        outline.rowHeight = 18
        outline.indentationPerLevel = 10
        outline.intercellSpacing = NSSize(width: 0, height: 1)
        outline.selectionHighlightStyle = .regular
        outline.backgroundColor = .clear
        outline.focusRingType = .none
        outline.allowsEmptySelection = true
        outline.allowsMultipleSelection = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.isEditable = false
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        scrollView.documentView = outline
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        tabStop.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: tabStop.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: tabStop.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: tabStop.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: tabStop.bottomAnchor),
        ])

        context.coordinator.outlineView = outline
        context.coordinator.tabStopView = tabStop
        appState.fileTreeOutlineView = outline
        context.coordinator.startObservingSettings()
        context.coordinator.reloadRoots()
        MainWindowKeyViewLoop.sync(appState: appState)
        return tabStop
    }

    func updateNSView(_ tabStop: NSView, context: Context) {
        // Access image path so SwiftUI retriggers sync when thumbnail highlight moves.
        _ = appState.fileData.currentImagePath
        context.coordinator.syncSelectionIfNeeded()
        context.coordinator.syncToActiveImageIfRequested()
        context.coordinator.focusTreeIfRequested()
        context.coordinator.collapseUIIfRequested()
        context.coordinator.expandToCurrentDirectoryIfRequested()
        if context.coordinator.consumeReloadIfRequested() {
            context.coordinator.reloadRoots()
        }
        context.coordinator.applyThemeIfNeeded()
        MainWindowKeyViewLoop.sync(appState: appState)
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDelegate, NSOutlineViewDataSource {
        let appState: AppState
        weak var outlineView: FileTreeOutlineView?
        weak var tabStopView: MainWindowTabFocusStopView?
        private var roots: [FileTreeNode] = []
        private var excludedPaths: [String] = []
        fileprivate var rootPaths: [String] = []

        private var settingsObserver: UUID?
        private var lastFocusToken = 0
        private var lastCollapseUIToken = 0
        private var lastExpandToken = 0
        private var lastReloadToken = 0
        private var lastSyncActiveImageToken = 0
        private var lastSyncedDirectory: String?
        private var lastSyncedImagePath: String?
        private var highlightSyncRetryCount = 0
        private var lastThemeID: String?
        private var pendingSingleClick: DispatchWorkItem?
        private var pendingHighlightSync: DispatchWorkItem?
        private var currentImageObserver: NSObjectProtocol?
        private var expandedDirectoryPaths: Set<String> = []
        fileprivate var userIsNavigatingTree = false
        private var userNavigationReset: DispatchWorkItem?

        init(appState: AppState) {
            self.appState = appState
            lastFocusToken = appState.fileTreeFocusToken
            lastCollapseUIToken = appState.fileTreeCollapseUIToken
            lastExpandToken = appState.fileTreeExpandToken
            lastReloadToken = appState.fileTreeReloadToken
        }

        func consumeReloadIfRequested() -> Bool {
            guard appState.fileTreeReloadToken != lastReloadToken else { return false }
            lastReloadToken = appState.fileTreeReloadToken
            return true
        }

        func focusTreeIfRequested() {
            guard appState.fileTreeFocusToken != lastFocusToken else { return }
            lastFocusToken = appState.fileTreeFocusToken
            appState.focusFileTreeKeyboardTarget()
        }

        func syncToActiveImageIfRequested() {
            guard appState.fileTreeSyncActiveImageToken != lastSyncActiveImageToken else { return }
            lastSyncActiveImageToken = appState.fileTreeSyncActiveImageToken
            lastSyncedDirectory = nil
            lastSyncedImagePath = nil
            syncSelection(retryCount: 0, force: true)
            appState.focusFileTreeKeyboardTarget()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                self.lastSyncedDirectory = nil
                self.lastSyncedImagePath = nil
                self.syncSelection(retryCount: 0, force: true)
                self.appState.focusFileTreeKeyboardTarget()
            }
        }

        func collapseUIIfRequested() {
            guard appState.fileTreeCollapseUIToken != lastCollapseUIToken else { return }
            lastCollapseUIToken = appState.fileTreeCollapseUIToken
            collapseAllAndExpandToHome()
        }

        func expandToCurrentDirectoryIfRequested() {
            guard appState.fileTreeExpandToken != lastExpandToken else { return }
            lastExpandToken = appState.fileTreeExpandToken
            let depth = appState.config.int(forKey: "shift_cmd_depth", default: 4)
            expandFromSelection(maxLevels: max(1, depth))
            syncSelection()
        }

        private func expandFromSelection(maxLevels: Int) {
            guard let outlineView, maxLevels > 0 else { return }
            let startNode: FileTreeNode?
            if outlineView.selectedRow >= 0,
               let selected = outlineView.item(atRow: outlineView.selectedRow) as? FileTreeNode {
                startNode = selected
            } else if let first = roots.first {
                startNode = first
            } else {
                startNode = nil
            }
            guard let startNode else { return }
            expandLevels(from: startNode, outlineView: outlineView, remaining: maxLevels)
        }

        private func expandLevels(from node: FileTreeNode, outlineView: NSOutlineView, remaining: Int) {
            guard remaining > 0, isDirectoryExpandable(node) else { return }
            node.loadChildrenIfNeeded(appState: appState, rootPaths: rootPaths)
            outlineView.reloadItem(node, reloadChildren: true)
            outlineView.expandItem(node)
            expandedDirectoryPaths.insert(node.path)
            guard remaining > 1, let children = node.children else { return }
            for child in children where child.isDirectory && isDirectoryExpandable(child) {
                expandLevels(from: child, outlineView: outlineView, remaining: remaining - 1)
            }
        }

        /// Filtered tree modes: expandable only when at least one child directory passes the tree filter (Python proxy `hasChildren`).
        fileprivate func isDirectoryExpandable(_ node: FileTreeNode) -> Bool {
            guard node.isDirectory else { return false }
            if appState.filterSettings.filteredTree == "all" { return true }
            return node.hasVisibleFilteredChildDirectories(appState: appState, rootPaths: rootPaths)
        }

        func applyThemeIfNeeded() {
            let themeID = appState.config.string(forKey: "ui_theme", default: "dark")
            guard themeID != lastThemeID else { return }
            lastThemeID = themeID
            outlineView?.needsDisplay = true
        }

        func markUserNavigatingTree(extended: Bool = false) {
            userIsNavigatingTree = true
            userNavigationReset?.cancel()
            pendingHighlightSync?.cancel()
            pendingHighlightSync = nil
            let delay: TimeInterval = extended ? 1.0 : 0.2
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.userIsNavigatingTree = false
                self.syncSelectionIfNeeded()
            }
            userNavigationReset = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        private func shouldDeferTreeHighlightSync() -> Bool {
            let pinUserDirectory = appState.userRequestedTreeDirectory != nil && !appState.specificFilesActive
            return userIsNavigatingTree && !pinUserDirectory
        }

        func syncSelectionIfNeeded() {
            switch appState.fileData.currentViewMode {
            case .slideshow, .slideshow2, .slideshow3:
                return
            default:
                break
            }
            if shouldDeferTreeHighlightSync() { return }
            let currentDir = treeHighlightDirectoryPath()
            let currentImage = appState.fileData.currentImagePath
            if currentDir == lastSyncedDirectory, currentImage == lastSyncedImagePath {
                return
            }
            scheduleDebouncedHighlightSync(retryCount: 0)
        }

        private func scheduleDebouncedHighlightSync(retryCount: Int = 0) {
            highlightSyncRetryCount = retryCount
            pendingHighlightSync?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.syncSelection(retryCount: self.highlightSyncRetryCount)
            }
            pendingHighlightSync = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }

        func cancelPendingSingleClick() {
            pendingSingleClick?.cancel()
            pendingSingleClick = nil
        }

        func scheduleSingleClickToggle(for node: FileTreeNode) {
            cancelPendingSingleClick()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let outlineView = self.outlineView else { return }
                if outlineView.isItemExpanded(node) {
                    outlineView.collapseItem(node, collapseChildren: false)
                    self.removeExpandedPath(node.path)
                } else {
                    guard self.isDirectoryExpandable(node) else { return }
                    node.loadChildrenIfNeeded(appState: self.appState, rootPaths: self.rootPaths)
                    self.reloadItemPreservingSelection(outlineView, node, reloadChildren: true)
                    outlineView.expandItem(node)
                    self.expandedDirectoryPaths.insert(node.path)
                }
            }
            pendingSingleClick = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }

        func handleDoubleClick(row: Int) {
            cancelPendingSingleClick()
            guard let outlineView, row >= 0,
                  let node = outlineView.item(atRow: row) as? FileTreeNode else { return }
            openDirectoryFromTree(node: node, outlineView: outlineView)
        }

        func handleContextMenu(for event: NSEvent) {
            guard let outlineView else { return }
            let point = outlineView.convert(event.locationInWindow, from: nil)
            let row = outlineView.row(at: point)

            if row >= 0, let node = outlineView.item(atRow: row) as? FileTreeNode, node.isDirectory {
                FileTreeContextMenu.show(for: event, directoryPath: node.path, in: outlineView, appState: appState)
                return
            }

            PaneMenuActions.shared.appState = appState
            let menu = SidebarPaneContextMenus.buildMenu(kind: .fileTree, appState: appState)
            NSMenu.popUpContextMenu(menu, with: event, for: outlineView)
        }

        func renameSelectedDirectory() {
            guard let outlineView,
                  let node = outlineView.item(atRow: outlineView.selectedRow) as? FileTreeNode,
                  FileTreePathRestrictions.canRenameDirectory(node.path) else { return }
            appState.fileOperations.beginRename(path: node.path)
            appState.fileTreeReloadToken += 1
        }

        func selectedDirectoryPath() -> String? {
            guard let outlineView, outlineView.selectedRow >= 0,
                  let node = outlineView.item(atRow: outlineView.selectedRow) as? FileTreeNode,
                  node.isDirectory else { return nil }
            return node.path
        }

        func toggleExpandSelectedDirectory() {
            guard let outlineView else { return }
            let row = outlineView.selectedRow
            guard row >= 0,
                  let node = outlineView.item(atRow: row) as? FileTreeNode,
                  node.isDirectory else { return }
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node, collapseChildren: false)
                removeExpandedPath(node.path)
                return
            }
            guard isDirectoryExpandable(node) else { return }
            node.loadChildrenIfNeeded(appState: appState, rootPaths: rootPaths)
            reloadItemPreservingSelection(outlineView, node, reloadChildren: true)
            outlineView.expandItem(node)
            expandedDirectoryPaths.insert(node.path)
        }

        func openSelectedDirectoryFromReturn() {
            guard let outlineView else { return }
            var row = outlineView.selectedRow
            if row < 0, outlineView.numberOfRows > 0 {
                row = 0
            }
            guard row >= 0,
                  let node = outlineView.item(atRow: row) as? FileTreeNode,
                  node.isDirectory else { return }
            if !outlineView.isItemExpanded(node), isDirectoryExpandable(node) {
                node.loadChildrenIfNeeded(appState: appState, rootPaths: rootPaths)
                reloadItemPreservingSelection(outlineView, node, reloadChildren: true)
                outlineView.expandItem(node)
                expandedDirectoryPaths.insert(node.path)
            }
            openDirectoryFromTree(node: node, outlineView: outlineView)
        }

        private func openDirectoryFromTree(node: FileTreeNode, outlineView: NSOutlineView) {
            appState.noteUserRequestedTreeDirectory(node.path)
            markUserNavigatingTree(extended: true)
            let keepPath = node.path
            appState.loadDirectory(node.path, saveHistory: true)
            DispatchQueue.main.async { [weak self, weak outlineView] in
                guard let self, let outlineView else { return }
                self.selectDirectoryInTree(path: keepPath, outlineView: outlineView, scroll: true)
                outlineView.window?.makeFirstResponder(outlineView)
            }
        }

        func selectDirectoryInTree(path: String, outlineView: NSOutlineView, scroll: Bool) {
            let normalized = standardizedPath(path)
            FileTreeFilter.addPriorityPath(normalized)
            guard let match = findNodeByPath(normalized) else { return }
            expandPath(to: match, outlineView: outlineView, preserveSelection: false)
            let row = outlineView.row(forItem: match)
            guard row >= 0 else { return }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            if scroll {
                outlineView.scrollRowToVisible(row)
            }
            lastSyncedDirectory = normalized
            lastSyncedImagePath = appState.fileData.currentImagePath
        }

        private func collapseAllAndExpandToHome() {
            guard let outlineView else { return }
            expandedDirectoryPaths.removeAll()
            for root in roots {
                collapseRecursive(node: root, outlineView: outlineView)
                outlineView.collapseItem(root, collapseChildren: true)
            }
            expandRootToHome(outlineView: outlineView)
        }

        private func collapseRecursive(node: FileTreeNode, outlineView: NSOutlineView) {
            node.children?.forEach { child in
                collapseRecursive(node: child, outlineView: outlineView)
                outlineView.collapseItem(child, collapseChildren: true)
            }
        }

        private func expandRootToHome(outlineView: NSOutlineView) {
            let homePath = FileManager.default.homeDirectoryForCurrentUser.path
            let homeName = (homePath as NSString).lastPathComponent

            for root in roots {
                outlineView.expandItem(root)
                expandedDirectoryPaths.insert(root.path)
                root.loadChildrenIfNeeded(appState: appState, rootPaths: rootPaths)
                outlineView.reloadItem(root, reloadChildren: true)

                if root.path == "/Volumes" {
                    root.children?.forEach { child in
                        child.loadChildrenIfNeeded(appState: appState, rootPaths: rootPaths)
                        outlineView.reloadItem(child, reloadChildren: true)
                        if child.children?.isEmpty == false {
                            outlineView.expandItem(child)
                            expandedDirectoryPaths.insert(child.path)
                        }
                    }
                }

                if root.path == "/Users",
                   let homeNode = root.children?.first(where: { $0.name == homeName }) {
                    homeNode.loadChildrenIfNeeded(appState: appState, rootPaths: rootPaths)
                    outlineView.reloadItem(homeNode, reloadChildren: true)
                    outlineView.expandItem(homeNode)
                    expandedDirectoryPaths.insert(homeNode.path)
                    let row = outlineView.row(forItem: homeNode)
                    if row >= 0 {
                        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                        outlineView.scrollRowToVisible(row)
                    }
                }
            }
        }

        func startObservingSettings() {
            guard settingsObserver == nil else { return }
            settingsObserver = UUID()
            FileTreeFilter.setUpdateHandler { [weak self] discoveredPaths in
                self?.refreshAfterDiscovery(discoveredPaths)
            }
            _ = appState.eventBus.subscribe(.filterTreeModeChanged) { [weak self] _ in
                Task { @MainActor in self?.reloadFilterResults(preserveExpansion: true) }
            }
            _ = appState.eventBus.subscribe(.filterPatternChanged) { [weak self] _ in
                Task { @MainActor in self?.reloadFilterResults(preserveExpansion: true) }
            }
            if currentImageObserver == nil {
                currentImageObserver = NotificationCenter.default.addObserver(
                    forName: .prowserCurrentImageChanged,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    let coordinator = self
                    Task { @MainActor in coordinator?.syncSelectionIfNeeded() }
                }
            }
            _ = appState.eventBus.subscribe(.directoryLoaded) { [weak self] _ in
                Task { @MainActor in self?.syncSelectionIfNeeded() }
            }
            NotificationCenter.default.addObserver(
                forName: .prowserCurrentIndexChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                let coordinator = self
                Task { @MainActor in coordinator?.syncSelectionIfNeeded() }
            }
        }

        /// Background discovery found images — refresh parent rows only (no full reload).
        func refreshAfterDiscovery(_ discoveredPaths: Set<String>) {
            guard let outlineView else { return }
            FileTreeFilter.clearShallowCache()
            let parentPaths = Set(discoveredPaths.map {
                URL(fileURLWithPath: $0).deletingLastPathComponent().standardizedFileURL.path
            })
            var pathsToReload = parentPaths
            pathsToReload.formUnion(discoveredPaths)
            for path in pathsToReload.sorted(by: { $0.count < $1.count }) {
                guard let node = findNodeByPath(path) else { continue }
                node.invalidateChildren()
                guard outlineView.row(forItem: node) >= 0 else { continue }
                outlineView.reloadItem(node, reloadChildren: true)
            }
            restoreTrackedExpansion(outlineView: outlineView)
            syncSelectionIfNeeded()
        }

        /// Re-filter visible branches without collapsing the tree.
        func reloadFilterResults(preserveExpansion: Bool) {
            guard let outlineView else { return }
            FileTreeFilter.clearShallowCache()

            if !preserveExpansion {
                expandedDirectoryPaths.removeAll()
                for root in roots { root.invalidateSubtree() }
                outlineView.reloadData()
                if let first = roots.first {
                    outlineView.expandItem(first)
                    expandedDirectoryPaths.insert(first.path)
                }
                syncSelectionIfNeeded()
                return
            }

            let pathsToRefresh = Set(expandedDirectoryPaths.flatMap { ancestorPaths(of: $0) })
            for path in pathsToRefresh.sorted(by: { $0.count < $1.count }) {
                guard let node = findNodeByPath(path) else { continue }
                node.invalidateChildren()
                guard outlineView.row(forItem: node) >= 0 else { continue }
                outlineView.reloadItem(node, reloadChildren: true)
            }
            restoreTrackedExpansion(outlineView: outlineView)
            syncSelectionIfNeeded()
        }

        private func ancestorPaths(of path: String) -> [String] {
            let normalized = FileTreeFilter.standardizedPath(path)
            var result: [String] = []
            var current = normalized
            while true {
                result.append(current)
                if isRootPath(current) { break }
                let parent = URL(fileURLWithPath: current).deletingLastPathComponent().standardizedFileURL.path
                if parent == current { break }
                current = parent
            }
            return result
        }

        private func restoreTrackedExpansion(outlineView: NSOutlineView) {
            for path in expandedDirectoryPaths.sorted(by: { $0.count < $1.count }) {
                guard let node = findNodeByPath(path) else { continue }
                expandPath(to: node, outlineView: outlineView)
            }
        }

        private func removeExpandedPath(_ path: String) {
            let prefix = path + "/"
            expandedDirectoryPaths = expandedDirectoryPaths.filter { expanded in
                expanded != path && !expanded.hasPrefix(prefix)
            }
        }

        func reloadRoots() {
            FileTreeFilter.invalidateCache()
            excludedPaths = PathExclusions.excludedPaths(config: appState.config)
            let showHidden = appState.config.bool(forKey: "show_hidden_directories", default: false)
            rootPaths = appState.config.rawSettings()["root_directories"] as? [String]
                ?? ThemeDefaults.defaultRootDirectories
            roots = rootPaths.map { path in
                let expanded = (path as NSString).expandingTildeInPath
                return FileTreeNode(path: expanded, isDirectory: true, showHidden: showHidden, excluded: excludedPaths)
            }
            expandedDirectoryPaths.removeAll()
            outlineView?.reloadData()
            if let first = roots.first {
                outlineView?.expandItem(first)
                expandedDirectoryPaths.insert(first.path)
            }
            lastSyncedDirectory = nil
            pendingHighlightSync?.cancel()
            syncSelection()
        }

        func syncSelection(retryCount: Int = 0, force: Bool = false) {
            switch appState.fileData.currentViewMode {
            case .slideshow, .slideshow2, .slideshow3:
                return
            default:
                break
            }
            guard let outlineView else { return }
            if !force, shouldDeferTreeHighlightSync() { return }

            if let directory = directoryToHighlightForTreeSync() {
                FileTreeFilter.addPriorityPath(directory)
                if let imagePath = appState.fileData.currentImagePath {
                    FileTreeFilter.addPriorityPath(
                        URL(fileURLWithPath: imagePath).deletingLastPathComponent().standardizedFileURL.path
                    )
                }

                guard let match = nodeForHighlight(path: directory, retryCount: retryCount) else { return }

                expandPath(to: match, outlineView: outlineView, preserveSelection: false)
                lastSyncedDirectory = directory
                lastSyncedImagePath = appState.fileData.currentImagePath

                let row = outlineView.row(forItem: match)
                if row >= 0 {
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    outlineView.scrollRowToVisible(row)
                }

                let pinUserDirectory = appState.userRequestedTreeDirectory != nil && !appState.specificFilesActive
                if pinUserDirectory,
                   let requested = appState.userRequestedTreeDirectory,
                   let imagePath = appState.fileData.currentImagePath {
                    let imageDir = FileTreeFilter.standardizedPath(
                        URL(fileURLWithPath: imagePath).deletingLastPathComponent().standardizedFileURL.path
                    )
                    if imageDir == FileTreeFilter.standardizedPath(requested) {
                        appState.clearUserRequestedTreeDirectory()
                    }
                }
            }
        }

        /// Directory row to expand/select (Python `highlight_current_directory` / `user_requested_directory`).
        private func directoryToHighlightForTreeSync() -> String? {
            if let requested = appState.userRequestedTreeDirectory,
               !appState.specificFilesActive {
                return FileTreeFilter.standardizedPath(requested)
            }
            return treeHighlightDirectoryPath()
        }

        private func treeHighlightDirectoryPath() -> String? {
            FileTreeFilter.directoryForTreeImageHighlight(appState: appState)
        }

        private func reloadItemPreservingSelection(
            _ outlineView: NSOutlineView,
            _ item: Any,
            reloadChildren: Bool
        ) {
            let selectedItem = outlineView.selectedRow >= 0
                ? outlineView.item(atRow: outlineView.selectedRow)
                : nil
            outlineView.reloadItem(item, reloadChildren: reloadChildren)
            guard let selectedItem else { return }
            let row = outlineView.row(forItem: selectedItem)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }

        private func nodeForHighlight(path: String, retryCount: Int) -> FileTreeNode? {
            if let node = findNodeByPath(path) {
                highlightSyncRetryCount = 0
                return node
            }
            refreshPathTowardHighlight(path)
            guard retryCount < 8 else { return nil }
            scheduleDebouncedHighlightSync(retryCount: retryCount + 1)
            return nil
        }

        /// Invalidate/load path segments so filtered or lazy branches can resolve (Python `_scroll_to_directory`).
        private func refreshPathTowardHighlight(_ targetPath: String) {
            guard let outlineView else { return }
            let normalized = standardizedPath(targetPath)
            guard let root = rootContaining(normalized: normalized) else { return }
            let rootNorm = standardizedPath(root.path)

            var current = root
            reloadItemPreservingSelection(outlineView, current, reloadChildren: true)

            if normalized == rootNorm { return }

            var remainder = String(normalized.dropFirst(rootNorm.count))
            if remainder.hasPrefix("/") { remainder.removeFirst() }

            for component in remainder.split(separator: "/").map(String.init) {
                current.invalidateChildren()
                current.loadChildrenIfNeeded(appState: appState, rootPaths: rootPaths)
                reloadItemPreservingSelection(outlineView, current, reloadChildren: true)
                guard let next = current.children?.first(where: { $0.name == component }) else { return }
                current = next
            }
        }

        private func standardizedPath(_ path: String) -> String {
            FileTreeFilter.standardizedPath(path)
        }

        private func isRootPath(_ normalized: String) -> Bool {
            roots.contains { standardizedPath($0.path) == normalized }
        }

        private func rootContaining(normalized: String) -> FileTreeNode? {
            roots.first { root in
                let rootNorm = standardizedPath(root.path)
                return normalized == rootNorm || normalized.hasPrefix(rootNorm + "/")
            }
        }

        /// Walk path components from the containing root — O(depth), not O(tree size).
        private func findNodeByPath(_ targetPath: String) -> FileTreeNode? {
            let normalized = standardizedPath(targetPath)
            guard let root = rootContaining(normalized: normalized) else { return nil }
            let rootNorm = standardizedPath(root.path)
            if rootNorm == normalized { return root }

            var current = root
            var remainder = String(normalized.dropFirst(rootNorm.count))
            if remainder.hasPrefix("/") { remainder.removeFirst() }
            guard !remainder.isEmpty else { return root }

            for component in remainder.split(separator: "/").map(String.init) {
                current.loadChildrenIfNeeded(appState: appState, rootPaths: rootPaths)
                if current.children?.contains(where: { $0.name == component }) != true {
                    current.invalidateChildren()
                    current.loadChildrenIfNeeded(appState: appState, rootPaths: rootPaths)
                    outlineView?.reloadItem(current, reloadChildren: true)
                }
                guard let next = current.children?.first(where: { $0.name == component }) else {
                    return nil
                }
                current = next
            }
            return current
        }

        private func expandPath(
            to node: FileTreeNode,
            outlineView: NSOutlineView,
            preserveSelection: Bool = true
        ) {
            let normalized = standardizedPath(node.path)
            guard let root = rootContaining(normalized: normalized) else { return }
            let rootNorm = standardizedPath(root.path)

            let selectedItem = outlineView.selectedRow >= 0
                ? outlineView.item(atRow: outlineView.selectedRow)
                : nil

            var chain: [FileTreeNode] = [root]
            if normalized != rootNorm {
                var remainder = String(normalized.dropFirst(rootNorm.count))
                if remainder.hasPrefix("/") { remainder.removeFirst() }
                var current = root
                for component in remainder.split(separator: "/").map(String.init) {
                    current.loadChildrenIfNeeded(appState: appState, rootPaths: rootPaths)
                    if current.children?.contains(where: { $0.name == component }) != true {
                        current.invalidateChildren()
                        current.loadChildrenIfNeeded(appState: appState, rootPaths: rootPaths)
                    }
                    reloadItemPreservingSelection(outlineView, current, reloadChildren: true)
                    guard let next = current.children?.first(where: { $0.name == component }) else { return }
                    chain.append(next)
                    current = next
                }
            }

            for item in chain {
                reloadItemPreservingSelection(outlineView, item, reloadChildren: true)
                outlineView.expandItem(item)
                expandedDirectoryPaths.insert(item.path)
            }

            if preserveSelection, let selectedItem {
                let row = outlineView.row(forItem: selectedItem)
                if row >= 0 {
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
            }
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? FileTreeNode else { return }
            expandedDirectoryPaths.insert(node.path)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? FileTreeNode else { return }
            removeExpandedPath(node.path)
        }

        // MARK: NSOutlineViewDataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? FileTreeNode else { return roots.count }
            node.loadChildrenIfNeeded(appState: appState, rootPaths: rootPaths)
            return node.children?.count ?? 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if let node = item as? FileTreeNode {
                return node.children![index]
            }
            return roots[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? FileTreeNode else { return false }
            return isDirectoryExpandable(node)
        }

        // MARK: NSOutlineViewDelegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("FileTreeCell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
                let view = NSTableCellView()
                view.identifier = identifier
                let imageView = NSImageView()
                imageView.imageScaling = .scaleProportionallyDown
                imageView.translatesAutoresizingMaskIntoConstraints = false
                let textField = NSTextField(labelWithString: "")
                textField.lineBreakMode = .byTruncatingMiddle
                textField.font = NSFont.systemFont(ofSize: 11)
                textField.isEditable = false
                textField.isSelectable = false
                textField.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(imageView)
                view.addSubview(textField)
                view.imageView = imageView
                view.textField = textField
                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
                    imageView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: 14),
                    imageView.heightAnchor.constraint(equalToConstant: 14),
                    textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 3),
                    textField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
                    textField.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                ])
                return view
            }()

            if let node = item as? FileTreeNode {
                cell.imageView?.image = NSWorkspace.shared.icon(forFile: node.path)
                var label = node.name
                if appState.renameStatusManager.isEnabled,
                   appState.renameStatusManager.directoryStatus(node.path) == true {
                    label += " ✓"
                }
                cell.textField?.stringValue = label
                cell.textField?.textColor = NSColor(appState.theme.colors.sidebarText)
            }
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
            guard let node = item as? FileTreeNode else { return false }
            guard isDirectoryExpandable(node) else { return false }
            node.loadChildrenIfNeeded(appState: appState, rootPaths: rootPaths)
            if appState.renameStatusManager.isEnabled {
                appState.renameStatusManager.scanVisibleDirectories(
                    [node.path],
                    config: appState.config
                )
            }
            reloadItemPreservingSelection(outlineView, node, reloadChildren: true)
            return true
        }

        func outlineView(_ outlineView: NSOutlineView, shouldShowCellExpansionFor item: Any) -> Bool {
            false
        }
    }
}

@MainActor
final class FileTreeOutlineView: NSOutlineView {
    weak var coordinator: FileTreeView.Coordinator?
    weak var appState: AppState?

    override func mouseDown(with event: NSEvent) {
        coordinator?.markUserNavigatingTree()
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)

        if event.modifierFlags.contains(.control) {
            coordinator?.handleContextMenu(for: event)
            return
        }

        if event.clickCount >= 2 {
            if row >= 0 {
                coordinator?.handleDoubleClick(row: row)
            }
            return
        }

        if row >= 0,
           let coordinator,
           let node = item(atRow: row) as? FileTreeNode,
           node.isDirectory {
            if coordinator.isDirectoryExpandable(node) {
                coordinator.scheduleSingleClickToggle(for: node)
            }
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            return
        }

        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        coordinator?.markUserNavigatingTree()
        coordinator?.handleContextMenu(for: event)
    }

    override func keyDown(with event: NSEvent) {
        if let coordinator, let appState,
           FileTreeKeyboard.handle(
               event: event,
               outlineView: self,
               coordinator: coordinator,
               appState: appState
           ) {
            return
        }
        coordinator?.markUserNavigatingTree()
        super.keyDown(with: event)
    }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if let field = responder as? NSTextField, field.isEditable {
            return false
        }
        return super.validateProposedFirstResponder(responder, for: event)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            appState?.syncFileTreeKeyboardFocus(from: window)
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let windowSnapshot = window
        let appStateSnapshot = appState
        let ok = super.resignFirstResponder()
        DispatchQueue.main.async {
            appStateSnapshot?.syncFileTreeKeyboardFocus(from: windowSnapshot)
        }
        return ok
    }
}

@MainActor
final class FileTreeNode: NSObject {
    let path: String
    let name: String
    let isDirectory: Bool
    private let showHidden: Bool
    private let excluded: [String]
    var children: [FileTreeNode]?
    private var didLoad = false

    init(path: String, isDirectory: Bool, showHidden: Bool, excluded: [String]) {
        self.path = path
        self.name = (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent
        self.isDirectory = isDirectory
        self.showHidden = showHidden
        self.excluded = excluded
        super.init()
    }

    func loadChildrenIfNeeded(appState: AppState, rootPaths: [String]) {
        guard isDirectory, !didLoad else { return }
        didLoad = true
        let url = URL(fileURLWithPath: path)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: showHidden ? [] : [.skipsHiddenFiles]
        ) else {
            children = []
            return
        }
        let normalizedRoots = rootPaths.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path
        }
        children = entries
            .filter { entry in
                !PathExclusions.isExcluded(entry.path, excluded: excluded)
            }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { entry -> FileTreeNode? in
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                guard isDir else { return nil }
                guard !FileTreeExcludedExtensions.shouldExcludeDirectory(named: entry.lastPathComponent) else {
                    return nil
                }
                if !FileTreeFilter.shouldShowDirectory(at: entry.path, appState: appState, rootPaths: normalizedRoots) {
                    return nil
                }
                return FileTreeNode(path: entry.path, isDirectory: true, showHidden: showHidden, excluded: excluded)
            }
    }

    func hasVisibleFilteredChildDirectories(appState: AppState, rootPaths: [String]) -> Bool {
        loadChildrenIfNeeded(appState: appState, rootPaths: rootPaths)
        return !(children?.isEmpty ?? true)
    }

    func invalidateChildren() {
        didLoad = false
        children = nil
    }

    func invalidateSubtree() {
        didLoad = false
        children?.forEach { $0.invalidateSubtree() }
        children = nil
    }
}
