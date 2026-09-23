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

        let scrollView = FileTreeScrollView()
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
        _ = appState.fileTreeSyncActiveImageToken
        FileTreeFilter.setFileTreePaneVisible(
            appState.effectiveLeftSidebarVisible
                && appState.config.bool(forKey: "file_tree_visible", default: true)
        )
        context.coordinator.syncSelectionIfNeeded()
        context.coordinator.syncToActiveImageIfRequested()
        context.coordinator.focusTreeIfRequested()
        context.coordinator.collapseUIIfRequested()
        context.coordinator.expandToCurrentDirectoryIfRequested()
        if context.coordinator.consumeReloadIfRequested() {
            let preserveExpansion = appState.fileTreeReloadPreservesExpansion
            appState.fileTreeReloadPreservesExpansion = false
            context.coordinator.reloadRoots(preserveExpansion: preserveExpansion)
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
        /// Standardized paths for user-added custom roots (shown at top of the tree).
        private var customUserRootPaths: Set<String> = []

        private var eventSubscriptions: EventBusSubscriptionBag?
        private var lastFocusToken = 0
        private var lastCollapseUIToken = 0
        private var lastExpandToken = 0
        private var lastReloadToken = 0
        private var lastSyncActiveImageToken = 0
        private var lastSyncedDirectory: String?
        private var lastSyncedImagePath: String?
        /// Last directory row expanded for thumbnail/list highlight (Python `_last_expanded_directory`).
        private var lastExpandedHighlightDirectory: String?
        private var highlightSyncRetryCount = 0
        private var lastThemeID: String?
        private var pendingSingleClick: DispatchWorkItem?
        private var pendingHighlightSync: DispatchWorkItem?
        private var expandedDirectoryPaths: Set<String> = []
        fileprivate var userIsNavigatingTree = false
        private var treeExpandInProgress = false
        private var expandGeneration = 0
        private var allModeExpandQueue: [(FileTreeNode, Int)] = []
        private var allModeExpandVisited: Set<String> = []
        private var filteredPathsToExpand: [String] = []
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
            lastExpandedHighlightDirectory = nil
            syncSelection(retryCount: 0, force: true)
        }

        func collapseUIIfRequested() {
            guard appState.fileTreeCollapseUIToken != lastCollapseUIToken else { return }
            lastCollapseUIToken = appState.fileTreeCollapseUIToken
            collapseAllAndExpandToHome()
        }

        func expandToCurrentDirectoryIfRequested() {
            guard appState.fileTreeExpandToken != lastExpandToken else { return }
            lastExpandToken = appState.fileTreeExpandToken
            performExpandFromKeyboardShortcut()
        }

        /// ⌘↩ — expand highlighted directory (Python `expand_file_tree`; batched to keep UI responsive).
        func performExpandFromKeyboardShortcut() {
            guard !treeExpandInProgress else { return }
            guard let outlineView, let startNode = expandStartNode() else { return }

            expandGeneration += 1
            let generation = expandGeneration
            allModeExpandQueue.removeAll()
            allModeExpandVisited.removeAll()
            filteredPathsToExpand.removeAll()
            treeExpandInProgress = true
            markUserNavigatingTree(extended: true)
            appState.noteUserRequestedTreeDirectory(startNode.path)

            let mode = appState.filterSettings.filteredTree
            if mode == "all" {
                let depth = max(1, appState.config.int(forKey: "shift_cmd_depth", default: 4))
                allModeExpandQueue = [(startNode, depth)]
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.drainAllModeExpandQueue(generation: generation)
                }
                return
            }

            let scanContext = makeExpandScanContext(startDir: startNode.path)
            Task.detached {
                let paths = FileTreeExpandRunner.discoverPathsToExpand(context: scanContext)
                await MainActor.run { [weak self] in
                    self?.beginFilteredModeExpand(
                        paths: paths,
                        startNode: startNode,
                        outlineView: outlineView,
                        generation: generation
                    )
                }
            }
        }

        private func expandStartNode() -> FileTreeNode? {
            guard let outlineView else { return nil }
            if outlineView.selectedRow >= 0,
               let selected = outlineView.item(atRow: outlineView.selectedRow) as? FileTreeNode {
                if selected.isDirectory { return selected }
                return findNodeByPath(
                    URL(fileURLWithPath: selected.path).deletingLastPathComponent().standardizedFileURL.path
                )
            }
            return roots.first
        }

        private func makeExpandScanContext(startDir: String) -> FileTreeExpandRunner.ScanContext {
            let mode = appState.filterSettings.filteredTree
            let pattern = appState.filterSettings.filterPattern
            let walkMaxDepth = appState.config.int(forKey: "search_depth", default: 4)
            let roots = appState.config.rootDirectoriesForFileTree().map { AppConfig.standardizedRootDirectoryPath($0) }
            return FileTreeExpandRunner.ScanContext(
                startDir: startDir,
                walkMaxDepth: walkMaxDepth,
                mode: mode,
                filterPattern: pattern,
                imageExtensions: appState.config.imageExtensions,
                excludedPaths: PathExclusions.excludedPaths(config: appState.config),
                includeHidden: appState.config.bool(forKey: "show_hidden_directories", default: false),
                followSymlinks: appState.config.bool(forKey: "follow_symlinks", default: false),
                enabledRootPaths: Set(roots)
            )
        }

        private func beginFilteredModeExpand(
            paths: [String],
            startNode: FileTreeNode,
            outlineView: NSOutlineView,
            generation: Int
        ) {
            guard generation == expandGeneration else { return }
            for path in paths {
                FileTreeFilter.addPriorityPath(path)
            }
            if !paths.isEmpty {
                reloadFilterResults(preserveExpansion: true)
            }
            expandOutlineNode(startNode, outlineView: outlineView)
            let startRow = outlineView.row(forItem: startNode)
            if startRow >= 0 {
                outlineView.scrollRowToVisible(startRow)
            }
            guard !paths.isEmpty else {
                finishTreeExpand(generation: generation)
                return
            }
            filteredPathsToExpand = paths
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.drainFilteredExpandQueue(generation: generation)
            }
        }

        private func drainAllModeExpandQueue(generation: Int, batchSize: Int = 12) {
            guard generation == expandGeneration, treeExpandInProgress else { return }
            guard let outlineView else {
                finishTreeExpand(generation: generation)
                return
            }

            var processed = 0
            while !allModeExpandQueue.isEmpty, processed < batchSize {
                let (node, remaining) = allModeExpandQueue.removeFirst()
                guard remaining > 0, isDirectoryExpandable(node) else { continue }
                let normalized = standardizedPath(node.path)
                guard allModeExpandVisited.insert(normalized).inserted else { continue }
                expandOutlineNode(node, outlineView: outlineView)
                if remaining > 1 {
                    node.loadChildrenIfNeeded(appState: appState, rootPaths: rootPaths)
                    if let children = node.children {
                        for child in children where child.isDirectory && isDirectoryExpandable(child) {
                            allModeExpandQueue.append((child, remaining - 1))
                        }
                    }
                }
                processed += 1
            }

            if !allModeExpandQueue.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.drainAllModeExpandQueue(generation: generation, batchSize: batchSize)
                }
            } else {
                finishTreeExpand(generation: generation)
            }
        }

        private func drainFilteredExpandQueue(generation: Int, batchSize: Int = 20) {
            guard generation == expandGeneration, treeExpandInProgress else { return }
            guard let outlineView else {
                finishTreeExpand(generation: generation)
                return
            }

            guard !filteredPathsToExpand.isEmpty else {
                finishTreeExpand(generation: generation)
                return
            }

            let end = min(batchSize, filteredPathsToExpand.count)
            let batch = Array(filteredPathsToExpand.prefix(end))
            filteredPathsToExpand.removeFirst(end)

            for path in batch {
                guard let node = findNodeByPath(path) else { continue }
                expandPath(to: node, outlineView: outlineView, preserveSelection: true)
            }

            if !filteredPathsToExpand.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                    self?.drainFilteredExpandQueue(generation: generation, batchSize: batchSize)
                }
            } else {
                finishTreeExpand(generation: generation)
            }
        }

        private func expandOutlineNode(_ node: FileTreeNode, outlineView: NSOutlineView) {
            guard isDirectoryExpandable(node) else { return }
            node.loadChildrenIfNeeded(appState: appState, rootPaths: rootPaths)
            if !outlineView.isItemExpanded(node) {
                outlineView.expandItem(node)
            }
            expandedDirectoryPaths.insert(node.path)
        }

        private func finishTreeExpand(generation: Int) {
            guard generation == expandGeneration else { return }
            publishExpandedPathsForDiscovery()
            treeExpandInProgress = false
        }

        /// Disclosure when any non-excluded child directory exists. Filtered visibility is applied when children load.
        fileprivate func isDirectoryExpandable(_ node: FileTreeNode) -> Bool {
            guard node.isDirectory else { return false }
            return FileTreeFilter.hasExpandableChildDirectory(at: node.path, appState: appState)
        }

        private func publishExpandedPathsForDiscovery() {
            FileTreeFilter.setExpandedDirectoryPaths(expandedDirectoryPaths)
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
                self?.userIsNavigatingTree = false
            }
            userNavigationReset = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        private func shouldDeferTreeHighlightSync() -> Bool {
            if treeExpandInProgress { return true }
            let pinUserDirectory = appState.userRequestedTreeDirectory != nil && !appState.specificFilesActive
            return userIsNavigatingTree && !pinUserDirectory
        }

        func syncSelectionIfNeeded() {
            switch appState.fileData.currentViewMode {
            case .slideshow, .slideshow2, .slideshow3, .browse:
                return
            default:
                break
            }
            guard treeHighlightSyncAllowed() else { return }
            if shouldDeferTreeHighlightSync() { return }
            let currentImage = appState.fileData.currentImagePath
            let currentDir = activeImageDirectoryForTreeSync()
            if treeHighlightAlreadySynced(imagePath: currentImage, directory: currentDir) {
                return
            }
            scheduleDebouncedHighlightSync(retryCount: 0)
        }

        /// Skip only when the active image and its directory row are already selected (Python `_last_highlighted_*`).
        private func treeHighlightAlreadySynced(imagePath: String?, directory: String?) -> Bool {
            guard let imagePath, let directory else { return false }
            let directoryNorm = standardizedPath(directory)
            guard imagePath == lastSyncedImagePath, directoryNorm == lastSyncedDirectory else { return false }
            return isTreeHighlightSyncedToDirectory(directory)
        }

        /// Directory row exists and is the current outline selection.
        private func isTreeHighlightSyncedToDirectory(_ directory: String?) -> Bool {
            guard let directory, let outlineView else { return false }
            let norm = standardizedPath(directory)
            guard let node = loadedNode(at: norm) else { return false }
            let row = outlineView.row(forItem: node)
            guard row >= 0 else { return false }
            return outlineView.selectedRow == row
        }

        private func loadedNode(at targetPath: String) -> FileTreeNode? {
            let normalized = standardizedPath(targetPath)
            if customUserRootPaths.contains(normalized),
               let customRoot = roots.first(where: { standardizedPath($0.path) == normalized }) {
                return customRoot
            }
            guard let root = rootContaining(normalized: normalized) else { return nil }
            let rootNorm = standardizedPath(root.path)
            if rootNorm == normalized { return root }
            var remainder = String(normalized.dropFirst(rootNorm.count))
            if remainder.hasPrefix("/") { remainder.removeFirst() }
            var current = root
            for component in remainder.split(separator: "/").map(String.init) {
                guard let next = current.children?.first(where: { $0.name == component }) else { return nil }
                current = next
            }
            return current
        }

        /// Port of `highlight_current_file` pane visibility guard.
        private func treeHighlightSyncAllowed() -> Bool {
            appState.effectiveLeftSidebarVisible
                && appState.config.bool(forKey: "file_tree_visible", default: true)
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
            appState.focusFileTreeKeyboardTarget()
            let point = outlineView.convert(event.locationInWindow, from: nil)
            let row = outlineView.row(at: point)

            if row >= 0, let node = outlineView.item(atRow: row) as? FileTreeNode, node.isDirectory {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
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
            let homePath = FileManager.default.homeDirectoryForCurrentUser.path
            let homeNorm = standardizedPath(homePath)
            FileTreeFilter.addPriorityPath(homeNorm)

            expandedDirectoryPaths.removeAll()
            for root in roots {
                collapseRecursive(node: root, outlineView: outlineView)
                outlineView.collapseItem(root, collapseChildren: true)
            }

            if let homeNode = expandRootToHome(outlineView: outlineView) {
                openDirectoryFromTree(node: homeNode, outlineView: outlineView)
            } else {
                appState.noteUserRequestedTreeDirectory(homePath)
                appState.loadDirectory(homePath, saveHistory: true)
                DispatchQueue.main.async { [weak self, weak outlineView] in
                    guard let self, let outlineView else { return }
                    self.selectDirectoryInTree(path: homePath, outlineView: outlineView, scroll: true)
                    outlineView.window?.makeFirstResponder(outlineView)
                    self.appState.focusFileTreeKeyboardTarget()
                }
            }
        }

        private func collapseRecursive(node: FileTreeNode, outlineView: NSOutlineView) {
            node.children?.forEach { child in
                collapseRecursive(node: child, outlineView: outlineView)
                outlineView.collapseItem(child, collapseChildren: true)
            }
        }

        @discardableResult
        private func expandRootToHome(outlineView: NSOutlineView) -> FileTreeNode? {
            let homePath = FileManager.default.homeDirectoryForCurrentUser.path
            let homeNorm = standardizedPath(homePath)
            let homeName = (homePath as NSString).lastPathComponent

            if let customHomeRoot = roots.first(where: { isCustomUserRoot($0) && standardizedPath($0.path) == homeNorm }) {
                outlineView.expandItem(customHomeRoot)
                expandedDirectoryPaths.insert(customHomeRoot.path)
                customHomeRoot.reloadChildren(appState: appState, rootPaths: rootPaths)
                outlineView.reloadItem(customHomeRoot, reloadChildren: true)
                selectTreeNode(customHomeRoot, outlineView: outlineView)
                return customHomeRoot
            }

            if let volumesRoot = roots.first(where: { standardizedPath($0.path) == standardizedPath("/Volumes") }) {
                outlineView.expandItem(volumesRoot)
                expandedDirectoryPaths.insert(volumesRoot.path)
                volumesRoot.reloadChildren(appState: appState, rootPaths: rootPaths)
                outlineView.reloadItem(volumesRoot, reloadChildren: true)
                volumesRoot.children?.forEach { child in
                    guard isDirectoryExpandable(child) else { return }
                    outlineView.expandItem(child)
                    expandedDirectoryPaths.insert(child.path)
                }
            }

            guard let usersRoot = roots.first(where: { standardizedPath($0.path) == standardizedPath("/Users") }) else {
                return nil
            }
            outlineView.expandItem(usersRoot)
            expandedDirectoryPaths.insert(usersRoot.path)
            usersRoot.reloadChildren(appState: appState, rootPaths: rootPaths)
            outlineView.reloadItem(usersRoot, reloadChildren: true)
            guard let homeNode = usersRoot.children?.first(where: { $0.name == homeName }) else { return nil }
            outlineView.expandItem(homeNode)
            expandedDirectoryPaths.insert(homeNode.path)
            selectTreeNode(homeNode, outlineView: outlineView)
            return homeNode
        }

        private func selectTreeNode(_ node: FileTreeNode, outlineView: NSOutlineView) {
            let row = outlineView.row(forItem: node)
            guard row >= 0 else { return }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        }

        private func isCustomUserRoot(_ node: FileTreeNode) -> Bool {
            customUserRootPaths.contains(standardizedPath(node.path))
        }

        private func refreshCustomUserRootPaths() {
            let filesystemRoots = Set(
                AppConfig.filesystemRootDirectoryPaths().map { AppConfig.standardizedRootDirectoryPath($0) }
            )
            customUserRootPaths = Set(
                rootPaths
                    .map { AppConfig.standardizedRootDirectoryPath($0) }
                    .filter { !filesystemRoots.contains($0) }
            )
        }

        func startObservingSettings() {
            guard eventSubscriptions == nil else { return }
            let bag = EventBusSubscriptionBag(bus: appState.eventBus)
            eventSubscriptions = bag
            FileTreeFilter.setUpdateHandler { [weak self] discoveredPaths in
                self?.refreshAfterDiscovery(discoveredPaths)
            }
            bag.subscribe(.filterTreeModeChanged) { [weak self] _ in
                self?.reloadFilterResults(preserveExpansion: true)
            }
            bag.subscribe(.filterPatternChanged) { [weak self] _ in
                self?.reloadFilterResults(preserveExpansion: true)
            }
            bag.subscribe(.currentImageChanged) { [weak self] _ in
                self?.syncSelectionIfNeeded()
            }
            bag.subscribe(.directoryLoaded) { [weak self] _ in
                self?.syncAfterDirectoryLoaded()
            }
        }

        /// New folder listing — clear skip flags so launch/CLI restore always highlights the tree once.
        private func syncAfterDirectoryLoaded() {
            lastSyncedDirectory = nil
            lastSyncedImagePath = nil
            lastExpandedHighlightDirectory = nil
            pendingHighlightSync?.cancel()
            syncSelection(retryCount: 0, force: true)
        }

        /// Background discovery finished — refresh parent rows only (no re-expand / no thumbnail resync).
        func refreshAfterDiscovery(_ discoveredPaths: Set<String>) {
            guard let outlineView else { return }
            let parentPaths = Set(discoveredPaths.map {
                URL(fileURLWithPath: $0).deletingLastPathComponent().standardizedFileURL.path
            })
            for path in parentPaths.sorted(by: { $0.count < $1.count }) {
                guard let node = findNodeByPath(path) else { continue }
                node.reloadChildren(appState: appState, rootPaths: rootPaths)
                guard outlineView.row(forItem: node) >= 0 else { continue }
                reloadItemPreservingSelection(outlineView, node, reloadChildren: true)
            }
            if outlineView.selectedRow < 0, !treeExpandInProgress {
                syncSelectionIfNeeded()
            }
        }

        /// Re-filter visible branches without collapsing the tree.
        func reloadFilterResults(preserveExpansion: Bool) {
            guard let outlineView else { return }
            FileTreeFilter.clearShallowCache()

            if !preserveExpansion {
                expandedDirectoryPaths.removeAll()
                for root in roots { root.invalidateSubtree() }
                outlineView.reloadData()
                publishExpandedPathsForDiscovery()
                syncSelectionIfNeeded()
                return
            }

            let pathsToRefresh = Set(expandedDirectoryPaths.flatMap { ancestorPaths(of: $0) })
            for path in pathsToRefresh.sorted(by: { $0.count < $1.count }) {
                guard let node = findNodeByPath(path) else { continue }
                node.reloadChildren(appState: appState, rootPaths: rootPaths)
                guard outlineView.row(forItem: node) >= 0 else { continue }
                reloadItemPreservingSelection(outlineView, node, reloadChildren: true)
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
            if let last = lastExpandedHighlightDirectory,
               last == path || last.hasPrefix(prefix) {
                lastExpandedHighlightDirectory = nil
            }
        }

        func reloadRoots(preserveExpansion: Bool = false) {
            let savedExpansion = preserveExpansion ? expandedDirectoryPaths : nil
            lastExpandedHighlightDirectory = nil
            FileTreeFilter.invalidateCache()
            excludedPaths = PathExclusions.excludedPaths(config: appState.config)
            let showHidden = appState.config.bool(forKey: "show_hidden_directories", default: false)
            rootPaths = appState.config.rootDirectoriesForFileTree()
            refreshCustomUserRootPaths()
            roots = rootPaths.map { path in
                let expanded = (path as NSString).expandingTildeInPath
                return FileTreeNode(path: expanded, isDirectory: true, showHidden: showHidden, excluded: excludedPaths)
            }
            lastSyncedDirectory = nil
            pendingHighlightSync?.cancel()
            guard let outlineView else { return }
            if let savedExpansion {
                expandedDirectoryPaths = savedExpansion
                publishExpandedPathsForDiscovery()
                outlineView.reloadData()
                restoreTrackedExpansion(outlineView: outlineView)
                syncSelection(retryCount: 0, force: true)
            } else {
                expandedDirectoryPaths.removeAll()
                publishExpandedPathsForDiscovery()
                outlineView.reloadData()
                syncSelection()
            }
        }

        func syncSelection(retryCount: Int = 0, force: Bool = false) {
            switch appState.fileData.currentViewMode {
            case .slideshow, .slideshow2, .slideshow3, .browse:
                return
            default:
                break
            }
            guard let outlineView else { return }
            guard force || treeHighlightSyncAllowed() else { return }
            if !force, shouldDeferTreeHighlightSync() { return }

            if let directory = directoryToHighlightForTreeSync() {
                let directoryNorm = standardizedPath(directory)
                let currentImage = appState.fileData.currentImagePath
                if !force, retryCount == 0, treeHighlightAlreadySynced(imagePath: currentImage, directory: directory) {
                    return
                }

                FileTreeFilter.setPriorityNavigationDirectory(directoryNorm)

                guard let match = nodeForHighlight(path: directory, retryCount: retryCount) else { return }

                expandPath(to: match, outlineView: outlineView, preserveSelection: false)

                let row = outlineView.row(forItem: match)
                if row >= 0 {
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    outlineView.scrollRowToVisible(row)
                }

                lastSyncedDirectory = directoryNorm
                lastSyncedImagePath = currentImage

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
            appState.reconcileUserRequestedTreeDirectoryWithActiveImage()
            if let requested = appState.userRequestedTreeDirectory,
               !appState.specificFilesActive {
                return FileTreeFilter.standardizedPath(requested)
            }
            return activeImageDirectoryForTreeSync()
        }

        private func treeHighlightDirectoryPath() -> String? {
            FileTreeFilter.directoryForTreeImageHighlight(appState: appState)
        }

        /// Stable directory for thumbnail/list highlight (Python `dirname(current_image_path)`).
        private func activeImageDirectoryForTreeSync() -> String? {
            if let path = appState.fileData.currentImagePath {
                let dir = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
                if !dir.isEmpty { return standardizedPath(dir) }
            }
            return treeHighlightDirectoryPath()
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
            guard retryCount < 8 else { return nil }
            scheduleDebouncedHighlightSync(retryCount: retryCount + 1)
            return nil
        }

        /// Descend from `root` along path components; loads children lazily, reloads only when a segment is missing.
        @discardableResult
        private func walkPathComponents(
            from root: FileTreeNode,
            toNormalizedPath normalized: String
        ) -> FileTreeNode? {
            let rootNorm = standardizedPath(root.path)
            if normalized == rootNorm { return root }

            var remainder = String(normalized.dropFirst(rootNorm.count))
            if remainder.hasPrefix("/") { remainder.removeFirst() }
            let components = remainder.split(separator: "/").map(String.init)
            guard !components.isEmpty else { return root }

            var current = root
            for component in components {
                guard let next = ensureChildLoaded(
                    parent: current,
                    component: component,
                    outlineView: outlineView
                ) else {
                    return nil
                }
                current = next
            }
            return current
        }

        /// Load one child segment under `parent`. Reloads the parent only when that child is missing.
        private func ensureChildLoaded(
            parent: FileTreeNode,
            component: String,
            outlineView: NSOutlineView?
        ) -> FileTreeNode? {
            parent.loadChildrenIfNeeded(appState: appState, rootPaths: rootPaths)
            if let existing = parent.children?.first(where: { $0.name == component }) {
                return existing
            }
            parent.reloadChildren(appState: appState, rootPaths: rootPaths)
            if let outlineView {
                reloadItemPreservingSelection(outlineView, parent, reloadChildren: true)
            }
            return parent.children?.first(where: { $0.name == component })
        }

        private func standardizedPath(_ path: String) -> String {
            FileTreeFilter.standardizedPath(path)
        }

        private func isRootPath(_ normalized: String) -> Bool {
            roots.contains { standardizedPath($0.path) == normalized }
        }

        private func rootContaining(normalized: String) -> FileTreeNode? {
            var best: FileTreeNode?
            var bestRootLength = -1
            for root in roots {
                let rootNorm = standardizedPath(root.path)
                guard normalized == rootNorm || normalized.hasPrefix(rootNorm + "/") else { continue }
                if rootNorm.count > bestRootLength {
                    best = root
                    bestRootLength = rootNorm.count
                }
            }
            return best
        }

        /// Walk path components from the containing root — O(depth), not O(tree size).
        private func findNodeByPath(_ targetPath: String) -> FileTreeNode? {
            let normalized = standardizedPath(targetPath)
            if customUserRootPaths.contains(normalized),
               let customRoot = roots.first(where: { standardizedPath($0.path) == normalized }) {
                return customRoot
            }
            guard let root = rootContaining(normalized: normalized) else { return nil }
            return walkPathComponents(from: root, toNormalizedPath: normalized)
        }

        private func expandPath(
            to node: FileTreeNode,
            outlineView: NSOutlineView,
            preserveSelection: Bool = true
        ) {
            let normalized = standardizedPath(node.path)
            if normalized == lastExpandedHighlightDirectory {
                let row = outlineView.row(forItem: node)
                if row >= 0 {
                    if outlineView.selectedRow != row {
                        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    }
                    outlineView.scrollRowToVisible(row)
                    return
                }
                lastExpandedHighlightDirectory = nil
            }

            guard let root = rootContaining(normalized: normalized) else { return }
            let rootNorm = standardizedPath(root.path)

            let selectedItem = preserveSelection && outlineView.selectedRow >= 0
                ? outlineView.item(atRow: outlineView.selectedRow)
                : nil

            var chain: [FileTreeNode] = [root]
            if normalized != rootNorm {
                var remainder = String(normalized.dropFirst(rootNorm.count))
                if remainder.hasPrefix("/") { remainder.removeFirst() }
                var current = root
                for component in remainder.split(separator: "/").map(String.init) {
                    guard let next = ensureChildLoaded(
                        parent: current,
                        component: component,
                        outlineView: outlineView
                    ) else {
                        return
                    }
                    chain.append(next)
                    current = next
                }
            }

            for item in chain where item.isDirectory {
                if !outlineView.isItemExpanded(item) {
                    outlineView.expandItem(item)
                    expandedDirectoryPaths.insert(item.path)
                }
            }
            publishExpandedPathsForDiscovery()
            lastExpandedHighlightDirectory = normalized

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
            publishExpandedPathsForDiscovery()
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? FileTreeNode else { return }
            removeExpandedPath(node.path)
            publishExpandedPathsForDiscovery()
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

        // MARK: File tree drop (validateDrop drives move/copy cursor badge)

        func outlineView(
            _ outlineView: NSOutlineView,
            validateDrop info: NSDraggingInfo,
            proposedItem item: Any?,
            proposedChildIndex _: Int
        ) -> NSDragOperation {
            let paths = FileTreeOutlineView.filePaths(from: info)
            guard !paths.isEmpty else { return [] }
            guard let node = item as? FileTreeNode, node.isDirectory else { return [] }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: node.path, isDirectory: &isDir), isDir.boolValue else {
                return []
            }
            outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex)
            let op = FileDragDropOperations.destinationOperation(
                sourceMask: info.draggingSourceOperationMask,
                filePaths: paths,
                targetDirectory: node.path
            )
            if let outline = outlineView as? FileTreeOutlineView {
                outline.storeTreeDropProposal(operation: op, targetDirectory: node.path)
            }
            // Badge follows `draggingUpdated` on the outline/scroll view; keep validateDrop in sync.
            return op
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            acceptDrop info: NSDraggingInfo,
            item: Any?,
            childIndex: Int
        ) -> Bool {
            guard let outline = outlineView as? FileTreeOutlineView else { return false }
            return outline.performStoredFileTreeDrop(from: info)
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
                let isDropTarget = (outlineView as? FileTreeOutlineView)?.dropHighlightPath == node.path
                cell.textField?.font = isDropTarget
                    ? NSFont.boldSystemFont(ofSize: 11)
                    : NSFont.systemFont(ofSize: 11)
                cell.textField?.textColor = NSColor(appState.theme.colors.sidebarText)
            }
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            let rowView = FileTreeDropHighlightRowView()
            if let node = item as? FileTreeNode,
               let outline = outlineView as? FileTreeOutlineView {
                rowView.isDropTarget = outline.dropHighlightPath == node.path
                rowView.showsDisclosureTriangle = isDirectoryExpandable(node)
            } else {
                rowView.showsDisclosureTriangle = false
            }
            return rowView
        }

        func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
            let show = (outlineView.item(atRow: row) as? FileTreeNode).map(isDirectoryExpandable) ?? false
            FileTreeDropHighlightRowView.applyDisclosureVisibility(to: rowView, show: show)
        }

        fileprivate func refreshDropHighlight(oldPath: String?, newPath: String?) {
            guard let outlineView else { return }
            applyDropHighlightAppearance(path: oldPath, highlighted: false, outlineView: outlineView)
            applyDropHighlightAppearance(path: newPath, highlighted: true, outlineView: outlineView)
        }

        private func applyDropHighlightAppearance(path: String?, highlighted: Bool, outlineView: NSOutlineView) {
            guard let path else { return }
            for row in 0..<outlineView.numberOfRows {
                guard let node = outlineView.item(atRow: row) as? FileTreeNode, node.path == path else { continue }
                if let rowView = outlineView.rowView(atRow: row, makeIfNecessary: false) as? FileTreeDropHighlightRowView {
                    rowView.isDropTarget = highlighted
                }
                if let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView {
                    cell.textField?.font = highlighted
                        ? NSFont.boldSystemFont(ofSize: 11)
                        : NSFont.systemFont(ofSize: 11)
                }
                break
            }
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

        func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
            guard let node = item as? FileTreeNode else { return false }
            return isDirectoryExpandable(node)
        }

        func outlineView(
            _: NSOutlineView,
            shouldShowCellExpansionFor _: NSTableColumn?,
            item _: Any
        ) -> Bool {
            false
        }
    }
}

@MainActor
final class FileTreeDropHighlightRowView: NSTableRowView {
    var isDropTarget = false {
        didSet {
            guard oldValue != isDropTarget else { return }
            needsDisplay = true
        }
    }

    var showsDisclosureTriangle = true {
        didSet {
            guard oldValue != showsDisclosureTriangle else { return }
            applyDisclosureVisibility()
        }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        applyDisclosureVisibility()
    }

    override func layout() {
        super.layout()
        applyDisclosureVisibility()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        if isDropTarget {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.45).setFill()
            bounds.fill()
            return
        }
        super.drawBackground(in: dirtyRect)
    }

    static func applyDisclosureVisibility(to rowView: NSTableRowView, show: Bool) {
        if let custom = rowView as? FileTreeDropHighlightRowView {
            custom.showsDisclosureTriangle = show
            custom.applyDisclosureVisibility()
            return
        }
        hideNonCellSubviews(in: rowView, show: show)
    }

    fileprivate func applyDisclosureVisibility() {
        Self.hideNonCellSubviews(in: self, show: showsDisclosureTriangle)
    }

    private static func hideNonCellSubviews(in rowView: NSTableRowView, show: Bool) {
        for subview in rowView.subviews where !(subview is NSTableCellView) {
            subview.isHidden = !show
            subview.alphaValue = show ? 1 : 0
        }
    }
}

/// Forwards drags so copy/move badges work when the outline is shorter than the scroll viewport.
@MainActor
final class FileTreeScrollView: NSScrollView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(FileTreeOutlineView.draggedTypes)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(FileTreeOutlineView.draggedTypes)
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    private var outline: FileTreeOutlineView? {
        documentView as? FileTreeOutlineView
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        outline?.draggingEntered(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        outline?.treeDropOperation(for: sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        outline?.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        outline?.prepareForDragOperation(sender) ?? false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        outline?.performDragOperation(sender) ?? false
    }
}

@MainActor
final class FileTreeOutlineView: NSOutlineView {
    weak var coordinator: FileTreeView.Coordinator?
    weak var appState: AppState?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(FileTreeOutlineView.draggedTypes)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(FileTreeOutlineView.draggedTypes)
    }

    fileprivate static let draggedTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        NSPasteboard.PasteboardType("public.file-url"),
        NSPasteboard.PasteboardType("NSFilenamesPboardType"),
    ]

    fileprivate var proposedDropOperation: NSDragOperation = []
    fileprivate var proposedDropDirectory: String?
    /// Survives `draggingExited`, which AppKit often sends immediately before `acceptDrop`.
    private var lastDropOperation: NSDragOperation = []
    private var lastDropDirectory: String?
    fileprivate var dropHighlightPath: String?

    fileprivate func storeTreeDropProposal(operation: NSDragOperation, targetDirectory: String) {
        proposedDropOperation = operation
        proposedDropDirectory = targetDirectory
        lastDropOperation = operation
        lastDropDirectory = targetDirectory
        setDropHighlightPath(targetDirectory)
    }

    fileprivate func consumeDropOperation() -> NSDragOperation {
        let operation = lastDropOperation != [] ? lastDropOperation : proposedDropOperation
        lastDropOperation = []
        return operation
    }

    fileprivate func consumeDropDirectory() -> String? {
        let directory = lastDropDirectory ?? proposedDropDirectory
        lastDropDirectory = nil
        return directory
    }

    fileprivate func clearTreeDropProposal() {
        proposedDropOperation = []
        proposedDropDirectory = nil
        setDropHighlightPath(nil)
    }

    private func setDropHighlightPath(_ path: String?) {
        let oldPath = dropHighlightPath
        guard oldPath != path else { return }
        dropHighlightPath = path
        coordinator?.refreshDropHighlight(oldPath: oldPath, newPath: path)
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    /// Drives the move/copy pointer badge (green + for copy). `validateDrop` alone does not update it.
    func treeDropOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        let paths = Self.filePaths(from: sender)
        guard !paths.isEmpty else {
            setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
            clearTreeDropProposal()
            return []
        }
        let point = convert(sender.draggingLocation, from: nil)
        let row = row(at: point)
        guard row >= 0,
              let node = item(atRow: row) as? FileTreeNode,
              node.isDirectory else {
            setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
            clearTreeDropProposal()
            return []
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: node.path, isDirectory: &isDir), isDir.boolValue else {
            clearTreeDropProposal()
            return []
        }
        setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
        let op = FileDragDropOperations.destinationOperation(
            sourceMask: sender.draggingSourceOperationMask,
            filePaths: paths,
            targetDirectory: node.path
        )
        storeTreeDropProposal(operation: op, targetDirectory: node.path)
        return op
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        lastDropOperation = []
        lastDropDirectory = nil
        return treeDropOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        treeDropOperation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        // Keep last copy/move so drop still runs after AppKit sends exited.
        clearTreeDropProposal()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if lastDropOperation == [], lastDropDirectory == nil {
            _ = treeDropOperation(for: sender)
        }
        let ok = lastDropOperation != [] && lastDropDirectory != nil
        appState?.config.debugLog(
            "FileTree prepareForDragOperation ok=\(ok) op=\(lastDropOperation.rawValue) dir=\(lastDropDirectory ?? "nil")"
        )
        return ok
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        performStoredFileTreeDrop(from: sender)
    }

    fileprivate func performStoredFileTreeDrop(from sender: NSDraggingInfo) -> Bool {
        let paths = Self.filePaths(from: sender)
        let target = lastDropDirectory ?? proposedDropDirectory
        let operation = lastDropOperation != [] ? lastDropOperation : proposedDropOperation
        lastDropOperation = []
        lastDropDirectory = nil
        clearTreeDropProposal()
        setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        guard !paths.isEmpty, let target, operation != [] else {
            appState?.config.debugLog(
                "FileTree drop rejected paths=\(paths.count) target=\(target ?? "nil") op=\(operation.rawValue)"
            )
            return false
        }
        appState?.config.debugLog(
            "FileTree drop \(operation == .copy ? "copy" : "move") \(paths.count) file(s) -> \(target)"
        )
        return appState?.fileOperations.performFileTreeDrop(
            filePaths: paths,
            targetDirectory: target,
            operation: operation
        ) ?? false
    }

    static func filePaths(from draggingInfo: NSDraggingInfo) -> [String] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] {
            let paths = urls.map(\.path).filter { !$0.isEmpty }
            if !paths.isEmpty { return paths }
        }
        if let names = draggingInfo.draggingPasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            return names
        }
        return []
    }

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
            appState?.focusFileTreeKeyboardTarget()
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
        children = Self.sortedDirectoryChildren(
            at: path,
            showHidden: showHidden,
            excluded: excluded,
            appState: appState,
            rootPaths: rootPaths
        )
    }

    /// Rescan and replace children in case-insensitive name order (used on filter/root refresh).
    func reloadChildren(appState: AppState, rootPaths: [String]) {
        guard isDirectory else { return }
        didLoad = false
        children = nil
        loadChildrenIfNeeded(appState: appState, rootPaths: rootPaths)
    }

    private static func sortedDirectoryChildren(
        at path: String,
        showHidden: Bool,
        excluded: [String],
        appState: AppState,
        rootPaths: [String]
    ) -> [FileTreeNode] {
        let url = URL(fileURLWithPath: path)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: showHidden ? [] : [.skipsHiddenFiles]
        ) else {
            return []
        }
        let normalizedRoots = rootPaths.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path
        }
        return entries
            .filter { entry in
                !PathExclusions.isExcluded(entry.path, excluded: excluded)
            }
            .sorted { AppConfig.comparePathsForFileTreeSort($0.path, $1.path) }
            .filter { !FileTreeExcludedExtensions.shouldExcludeDirectory(named: $0.lastPathComponent) }
            .compactMap { entry -> FileTreeNode? in
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                guard isDir else { return nil }
                if !FileTreeFilter.shouldShowDirectory(at: entry.path, appState: appState, rootPaths: normalizedRoots) {
                    return nil
                }
                return FileTreeNode(path: entry.path, isDirectory: true, showHidden: showHidden, excluded: excluded)
            }
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
