import AppKit
import SwiftUI

/// Lazy file system tree for the left sidebar. Port of `files/file_tree_handler.py`.
struct FileTreeView: NSViewRepresentable {
    @Environment(AppState.self) private var appState

    func makeCoordinator() -> Coordinator {
        Coordinator(appState: appState)
    }

    func makeNSView(context: Context) -> NSScrollView {
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
        context.coordinator.outlineView = outline
        context.coordinator.startObservingSettings()
        context.coordinator.reloadRoots()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Access image path so SwiftUI retriggers sync when thumbnail highlight moves.
        _ = appState.fileData.currentImagePath
        context.coordinator.syncSelectionIfNeeded()
        context.coordinator.focusTreeIfRequested()
        context.coordinator.collapseUIIfRequested()
        context.coordinator.expandToCurrentDirectoryIfRequested()
        if context.coordinator.consumeReloadIfRequested() {
            context.coordinator.reloadRoots()
        }
        context.coordinator.applyThemeIfNeeded()
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDelegate, NSOutlineViewDataSource {
        let appState: AppState
        weak var outlineView: FileTreeOutlineView?
        private var roots: [FileTreeNode] = []
        private var excludedPaths: [String] = []
        fileprivate var rootPaths: [String] = []

        private var settingsObserver: UUID?
        private var lastFocusToken = 0
        private var lastCollapseUIToken = 0
        private var lastExpandToken = 0
        private var lastReloadToken = 0
        private var lastSyncedDirectory: String?
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
            outlineView?.window?.makeFirstResponder(outlineView)
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
            guard remaining > 0 else { return }
            node.loadChildrenIfNeeded(appState: appState, rootPaths: rootPaths)
            outlineView.reloadItem(node, reloadChildren: true)
            outlineView.expandItem(node)
            expandedDirectoryPaths.insert(node.path)
            guard remaining > 1, let children = node.children else { return }
            for child in children where child.isDirectory {
                expandLevels(from: child, outlineView: outlineView, remaining: remaining - 1)
            }
        }

        func applyThemeIfNeeded() {
            let themeID = appState.config.string(forKey: "ui_theme", default: "dark")
            guard themeID != lastThemeID else { return }
            lastThemeID = themeID
            outlineView?.needsDisplay = true
        }

        func markUserNavigatingTree() {
            userIsNavigatingTree = true
            userNavigationReset?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.userIsNavigatingTree = false
            }
            userNavigationReset = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }

        func syncSelectionIfNeeded() {
            switch appState.fileData.currentViewMode {
            case .slideshow, .slideshow2, .slideshow3:
                return
            default:
                break
            }
            let current = FileTreeFilter.highlightDirectory(appState: appState)
            guard current != lastSyncedDirectory else { return }
            scheduleDebouncedHighlightSync()
        }

        private func scheduleDebouncedHighlightSync() {
            pendingHighlightSync?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.syncSelection()
            }
            pendingHighlightSync = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13, execute: work)
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
                    node.loadChildrenIfNeeded(appState: self.appState, rootPaths: self.rootPaths)
                    outlineView.reloadItem(node, reloadChildren: true)
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
            appState.loadDirectory(node.path, saveHistory: true)
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
        }

        /// Background discovery found images — refresh parent rows only (no full reload).
        func refreshAfterDiscovery(_ discoveredPaths: Set<String>) {
            guard let outlineView else { return }
            FileTreeFilter.clearShallowCache()
            let parentPaths = Set(discoveredPaths.map {
                URL(fileURLWithPath: $0).deletingLastPathComponent().standardizedFileURL.path
            })
            for parentPath in parentPaths.sorted(by: { $0.count < $1.count }) {
                guard let parent = findNodeByPath(parentPath) else { continue }
                parent.invalidateChildren()
                guard outlineView.row(forItem: parent) >= 0 else { continue }
                outlineView.reloadItem(parent, reloadChildren: true)
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

        func syncSelection() {
            switch appState.fileData.currentViewMode {
            case .slideshow, .slideshow2, .slideshow3:
                return
            default:
                break
            }
            guard let outlineView, let current = FileTreeFilter.highlightDirectory(appState: appState) else { return }
            FileTreeFilter.addPriorityPath(current)
            guard let match = findNodeByPath(current) else { return }
            expandPath(to: match, outlineView: outlineView)
            lastSyncedDirectory = current
            if userIsNavigatingTree { return }
            let row = outlineView.row(forItem: match)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outlineView.scrollRowToVisible(row)
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

        private func expandPath(to node: FileTreeNode, outlineView: NSOutlineView) {
            let normalized = standardizedPath(node.path)
            guard let root = rootContaining(normalized: normalized) else { return }
            let rootNorm = standardizedPath(root.path)

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
                    outlineView.reloadItem(current, reloadChildren: true)
                    guard let next = current.children?.first(where: { $0.name == component }) else { return }
                    chain.append(next)
                    current = next
                }
            }

            for item in chain {
                outlineView.reloadItem(item, reloadChildren: true)
                outlineView.expandItem(item)
                expandedDirectoryPaths.insert(item.path)
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
            (item as? FileTreeNode)?.isDirectory == true
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
            if let node = item as? FileTreeNode {
                node.loadChildrenIfNeeded(appState: appState, rootPaths: rootPaths)
                if appState.renameStatusManager.isEnabled {
                    appState.renameStatusManager.scanVisibleDirectories(
                        [node.path],
                        config: appState.config
                    )
                }
                outlineView.reloadItem(node, reloadChildren: true)
            }
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
            node.loadChildrenIfNeeded(appState: coordinator.appState, rootPaths: coordinator.rootPaths)
            if (node.children?.count ?? 0) > 0 {
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
        coordinator?.markUserNavigatingTree()
        if event.keyCode == 120 {
            coordinator?.renameSelectedDirectory()
            return
        }
        super.keyDown(with: event)
    }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if let field = responder as? NSTextField, field.isEditable {
            return false
        }
        return super.validateProposedFirstResponder(responder, for: event)
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
