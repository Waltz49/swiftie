import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shared application state container (models + config).
@Observable
@MainActor
final class AppState {
    let config: AppConfig
    let eventBus: AppEventBus
    let modelEventBridge: ModelEventBridge
    let fileData: FileDataModel
    let selection: SelectionModel
    let filterSettings: FilterSettingsModel
    let thumbnailCache: ThumbnailCache
    let metadataCache: MetadataCacheService
    let previewPaneCache = PreviewPaneSessionCache()
    let fileOperations: FileOperationsService
    let exifOperations = ExifOperationsController()
    let searchOperations = SearchOperationsService()
    let imageRecognition: ImageRecognitionService
    let backgroundImageRecognition = BackgroundImageRecognitionController()
    let fileTreeOperations = FileTreeOperationsService()
    let renamePrefixService = RenamePrefixService()
    let status = StatusNotificationService()
    let keyboardHandler = KeyboardHandlerController()
    private let statusBarPeekMonitor = StatusBarPeekMonitor()
    private let aboutDialog = AboutDialogController()
    private let settingsDialog = SettingsDialogController()
    private let auxiliaryDialogs = AuxiliaryDialogController()
    let theme: ThemeService
    let informationSectionState: InformationSectionState
    let leftSidebarSplit: SidebarPaneSplitModel
    let rightSidebarSplit: SidebarPaneSplitModel
    let directoryHistory = DirectoryHistory()
    let browseImageHistory = BrowseImageHistoryController()
    var fileTreeFocusToken = 0
    /// Tree pane keyboard focus (Python `combined_sidebar._update_tree_header_focus`).
    var fileTreeKeyboardFocused = false
    var fileTreeSyncActiveImageToken = 0
    /// While set, tree highlight follows this directory until the active image catches up (Python `user_requested_directory`).
    var userRequestedTreeDirectory: String?
    var userRequestedTreeClearWork: DispatchWorkItem?
    var settingsOpenRequestToken = 0
    var requestedSettingsTab: SettingsTab = .general
    var showKeyboardHelp = false
    var showImageRecognitionCaveats = false
    var showSimilaritySearchSheet = false
    var showClipSearchSheet = false
    var isAboutDialogVisible: Bool { aboutDialog.isVisible }
    var isSettingsDialogVisible: Bool { settingsDialog.isVisible }
    var showFindReferencesSheet = false
    var showReferenceGraphSheet = false
    var referenceGraphActive = false
    var referenceGraphFocusPath: String?
    var referenceGraphData: ReferenceGraph?
    var slideshow2ViewportSize = CGSize(width: 800, height: 600)
    var statusBarPeekActive = false
    var browseReturnThumbnailState: BrowseReturnThumbnailState?
    var lastViewMode: ViewMode = .thumbnail
    var showFilterDialog = false
    var showConvertFormatSheet = false
    var showResizeSheet = false
    var renamePrefixDialog: RenamePrefixDialogRequest?
    var showEditUserCommentSheet = false

    /// True when a modal SwiftUI sheet should receive keyboard input exclusively.
    var hasModalSheetPresented: Bool {
        showFilterDialog
            || showConvertFormatSheet
            || showResizeSheet
            || renamePrefixDialog != nil
            || showEditUserCommentSheet
            || exifBatchConfirmation != nil
            || showFindReferencesSheet
            || showReferenceGraphSheet
            || showKeyboardHelp
            || showImageRecognitionCaveats
            || showSimilaritySearchSheet
            || showClipSearchSheet
            || isAboutDialogVisible
            || showMoveWorkFilesSheet
    }
    var editUserCommentText = ""
    var editUserCommentOriginalText = ""
    var editUserCommentPath: String?
    var editUserCommentError: String?
    var findReferencesTargetPath: String?
    var findReferencesMatches: [String] = []
    var exifBatchConfirmation: ExifBatchConfirmationState?
    var chromeLayoutOverride: ChromeLayoutSnapshot?
    var numberOverlayVisible = false
    var chromeSuppressed = false
    var fileTreeToolbarVisible = true
    var informationMenuBarVisible = true
    /// True when viewing a custom file list (opened files, search results, etc.) — disables directory watcher refresh.
    var specificFilesActive = false
    /// Set when ⌘Q already confirmed quit so `applicationShouldTerminate` does not prompt twice.
    private var quitConfirmedViaClose = false
    /// Live column count from the thumbnail grid layout (source of truth for keyboard navigation).
    var thumbnailGridColumns = 1
    /// Visual row map for duplicate-section thumbnail ↑/↓ (from live grid layout).
    var thumbnailSectionedRowLayout: ThumbnailSectionedLayout.RowLayout?
    /// Bumped when on-disk image content changes so list/thumbnail views reload affected thumbs.
    var thumbnailInvalidationGeneration = 0
    /// Bumped when the active browse image file changes on disk at the same path.
    var browseImageContentRevision = 0
    var fileTreeCollapseUIToken = 0
    var fileTreeExpandToken = 0
    var fileTreeReloadToken = 0
    var fileOpsTargetPaths: [String] = []
    /// Session-only last file-tree drop destination for ⌘0 / ⌥⌘0 (Python `_last_drop_location`).
    var lastDropLocation: String?
    /// Paths deleted in formatted-list mode; slot preserved with red-X overlay (Python `deleted_file_placeholders`).
    var deletedFilePlaceholders: Set<String> = []
    /// Section boundaries for duplicate-group thumbnail layout (Python `duplicate_sections`).
    var duplicateSections: [DuplicateGroupPresentation.DuplicateSection] = []
    let menuRefresh = MenuRefreshState()
    let renameStatusManager: RenameStatusManager
    weak var thumbnailGridHost: ThumbnailGridNSView?
    weak var fileTreeOutlineView: FileTreeOutlineView?
    weak var browseImageHost: BrowseImageNSView?
    weak var listViewHost: ImageListNSView?
    weak var mainWindowTreeTabStop: MainWindowTabFocusStopView?
    weak var mainWindowCanvasTabStop: MainWindowTabFocusStopView?
    var showMoveWorkFilesSheet = false
    var leftSidebarWidth: CGFloat = 300
    var rightSidebarWidth: CGFloat = 300
    var sidebarLayoutRevision = 0
    /// True while `PreviewPaneView` is mounted (Python `preview_widget.isVisible()`).
    var previewPaneInLayout = false
    var chromeSavedLayout: ChromeSavedLayout?
    private let directoryWatcher = DirectoryWatcher()
    private var pipeListener: NamedPipeListener?
    private var suppressDirectoryRefreshUntil: Date?

    let launchOptions: LaunchOptions
    private(set) var directoryLoader: DirectoryLoadCoordinator!

    init(launchOptions: LaunchOptions = LaunchOptions.parse()) {
        self.launchOptions = launchOptions
        let config = AppConfig(profilePath: launchOptions.profilePath)
        self.config = config
        let eventBus = AppEventBus()
        self.eventBus = eventBus
        let modelEventBridge = ModelEventBridge(eventBus: eventBus)
        self.modelEventBridge = modelEventBridge
        self.fileData = FileDataModel(eventBridge: modelEventBridge)
        self.selection = SelectionModel(eventBridge: modelEventBridge)
        self.filterSettings = FilterSettingsModel(config: nil, eventBridge: modelEventBridge)
        filterSettings.bindConfig(config)

        if let pattern = launchOptions.filterPattern {
            filterSettings.setFilterPattern(pattern, persist: false)
        }

        config.loadSettings()
        config.applyLaunchDebugFlag(launchOptions.debug)
        migrateSwiftSidebarDefaults(config: config)
        discardPersistedLastDropLocation(config: config)
        leftSidebarSplit = SidebarPaneSplitModel(side: .left, config: config)
        rightSidebarSplit = SidebarPaneSplitModel(side: .right, config: config)
        leftSidebarWidth = SidebarWidthLimits.clampLeft(config.sidebarWidth)
        rightSidebarWidth = SidebarWidthLimits.clampRight(config.rightSidebarWidth)
        filterSettings.loadFromConfig()
        previewPaneInLayout = Self.previewPaneIsConfiguredVisible(
            config: config,
            viewMode: fileData.currentViewMode
        )
        let profilePaths = ProfilePaths(profilePath: launchOptions.profilePath)
        ModelManifest.loadUserCatalog(profile: profilePaths)
        imageRecognition = ImageRecognitionService(profile: profilePaths)
        imageRecognition.rebind(config: config)
        thumbnailCache = ThumbnailCache(
            paths: profilePaths,
            ignoreExifRotation: config.ignoreExifRotation
        )
        metadataCache = MetadataCacheService(paths: profilePaths)
        renameStatusManager = RenameStatusManager(dataDirectory: config.dataDirectory)
        fileOperations = FileOperationsService()
        theme = ThemeService(config: config)
        informationSectionState = InformationSectionState(config: config)
        loadSidebarToolbarSettings()
        observeViewModeChanges()
        directoryLoader = DirectoryLoadCoordinator(appState: self)
        fileOperations.bind(self)
        exifOperations.bind(self)
        searchOperations.bind(self)
        backgroundImageRecognition.bind(self)
        NotificationCenter.default.addObserver(
            forName: .imageRecognitionModelsInstalled,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshImageRecognitionForCurrentSettings()
        }
        fileTreeOperations.bind(self)
        renamePrefixService.bind(self)
        menuRefresh.bind(self)
        keyboardHandler.bind(self)
        statusBarPeekMonitor.bind(self)
        browseImageHistory.bind(self)
        KeyboardInputTracer.installIfNeeded(config: config)

        directoryHistory.referenceGraphStateProvider = { [weak self] in
            guard let self else { return (active: false, focusPath: nil) }
            return (active: self.referenceGraphActive, focusPath: self.referenceGraphFocusPath)
        }
        directoryHistory.duplicateStateProvider = { [weak self] in
            guard let self else { return (specificFilesActive: false, duplicateSections: []) }
            return (specificFilesActive: self.specificFilesActive, duplicateSections: self.duplicateSections)
        }

        // Lifetime bus subscriptions (app teardown ends the process).
        _ = eventBus.subscribe(.settingsChanged) { [weak self] _ in
            guard let self else { return }
            self.loadSidebarToolbarSettings()
            self.theme.reload()
            KeyboardInputTracer.installIfNeeded(config: self.config)
            // Do not rescan `currentDirectory` in specific-files / reference levels — same as
            // `openReferenceGraphPresentation` (a full `loadDirectory` clears the aggregate grid).
            guard !self.specificFilesActive, !self.referenceGraphActive else { return }
            if let dir = self.fileData.currentDirectory {
                self.loadDirectory(dir, saveHistory: false)
            }
        }

        directoryWatcher.onRefresh = { [weak self] in
            guard let self else { return }
            DirectoryRefreshService.checkAndRefreshIfChanged(appState: self)
        }

        _ = eventBus.subscribe(.filesChangedOnDisk) { [weak self] event in
            guard let self, case .string(let directory) = event.payload else { return }
            guard let current = self.fileData.currentDirectory,
                  Self.directoryPathsMatch(directory, current) else { return }
            DirectoryRefreshService.checkAndRefreshIfChanged(appState: self)
        }

        _ = eventBus.subscribe(.currentImageChanged) { [weak self] event in
            let path: String?
            if case .string(let value) = event.payload {
                path = value
            } else {
                path = nil
            }
            self?.browseImageHistory.onCurrentImageChanged(path)
        }
        _ = eventBus.subscribe(.viewModeChanged) { [weak self] _ in
            self?.browseImageHistory.onViewModeChanged()
            self?.persistRestoreState()
        }

        startNamedPipeListener()
        refreshMenuState()
    }

    var spaceKeyMode: String {
        config.string(forKey: "space_key_mode", default: "exit")
    }

    func toggleSpaceKeyMode() {
        let next = spaceKeyMode == "exit" ? "advance" : "exit"
        config.updateSetting("space_key_mode", value: next)
        status.show(next == "advance" ? "Space key mode: Advance to next image" : "Space key mode: Exit browse view")
    }

    func openBrowseImageHistory() {
        browseImageHistory.openHistory()
    }

    func swapBrowseImageHistoryFirstTwoAndShow() {
        browseImageHistory.swapFirstTwoAndShow()
    }

    func presentConvertFormatSheet(paths: [String]? = nil) {
        let resolved = resolvedFileOpsPaths(paths)
        guard !resolved.isEmpty else {
            status.show("No images selected")
            return
        }
        fileOpsTargetPaths = resolved
        showConvertFormatSheet = true
    }

    func presentResizeSheet(paths: [String]? = nil) {
        let resolved = resolvedFileOpsPaths(paths)
        guard !resolved.isEmpty else {
            status.show("No images selected")
            return
        }
        fileOpsTargetPaths = resolved
        showResizeSheet = true
    }

    private func resolvedFileOpsPaths(_ paths: [String]?) -> [String] {
        if let paths, !paths.isEmpty {
            return paths.filter { FileManager.default.fileExists(atPath: $0) }
        }
        if !selection.selectedFiles.isEmpty {
            return Array(selection.selectedFiles).filter { FileManager.default.fileExists(atPath: $0) }
        }
        if let current = fileData.currentImagePath,
           FileManager.default.fileExists(atPath: current) {
            return [current]
        }
        return []
    }

    func copyUserCommentToClipboard() {
        Task {
            guard let text = await userCommentForActiveImageAsync() else {
                status.show("No user comment to copy")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            status.show("Copied user comment")
        }
    }

    /// File Information pane copy button / `copy://` link (Python `usercomment_text_for_clipboard`).
    func copyInformationComment(full: Bool, preferredText: String? = nil) {
        Task { @MainActor in
            var text = preferredText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty, let path = fileData.currentImagePath {
                text = await ExifService.userDescription(path: path)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            guard !text.isEmpty else {
                status.show("No user comment to copy")
                return
            }
            let clipboard = ExifService.userCommentTextForClipboard(text, copyFull: full)
            guard !clipboard.isEmpty else {
                status.show("No prompt text to copy")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(clipboard, forType: .string)
            status.show(full ? "Copied full user comment" : "Copied prompt to clipboard")
        }
    }

    func reverseSortOrder() {
        let mode = SortMode(rawValue: config.string(forKey: "sort_mode", default: "date")) ?? .date
        if fileData.currentViewMode == .list {
            fileData.setViewMode(.thumbnail)
        }
        guard fileData.currentViewMode == .thumbnail || fileData.currentViewMode == .browse else { return }
        guard !fileData.displayedImages.isEmpty else { return }

        if mode == .random {
            let reversed = Array(fileData.displayedImages.reversed())
            fileData.setDisplayedImages(reversed)
            status.show("Sort order reversed")
            return
        }

        let reversed = !config.bool(forKey: "sort_reversed", default: false)
        config.updateSetting("sort_reversed", value: reversed)
        applyCurrentSort()
        status.show("Sort order reversed")
    }

    func applyRandomSort() {
        if fileData.currentViewMode == .list {
            fileData.setViewMode(.thumbnail)
        }
        let wasRandom = config.string(forKey: "sort_mode", default: "date") == SortMode.random.rawValue
        config.updateSetting("sort_mode", value: SortMode.random.rawValue)
        applyCurrentSort()
        status.show(wasRandom ? "Random Sort (reshuffled)" : "Random Sort")
    }

    func quickMassRename() {
        renamePrefixService.quickMassRename()
    }

    func renameWithCustomPrefix() {
        renamePrefixService.renameWithCustomPrefix()
    }

    func backupCustomSort() {
        guard let directory = fileData.currentDirectory else {
            status.show("No directory is currently open")
            return
        }
        do {
            let backupPath = try PrsortBackupService.backup(in: directory)
            status.show("Custom sort backed up to \(backupPath)")
        } catch {
            status.show(error.localizedDescription)
        }
    }

    func restoreCustomSort() {
        guard let directory = fileData.currentDirectory else {
            status.show("No directory is currently open")
            return
        }
        do {
            try PrsortBackupService.restore(in: directory, extensions: config.imageExtensions)
            refreshDirectory()
            status.show("Custom sort restored")
        } catch {
            status.show(error.localizedDescription)
        }
    }

    func prepopulateSubdirectoryThumbnails() {
        guard let directory = fileData.currentDirectory else {
            status.show("No directory loaded")
            return
        }
        Task {
            let depth = config.int(forKey: "search_depth", default: 4)
            let size = config.int(forKey: "thumbnail_cell_size", default: 256)
            let count = await thumbnailCache.prepopulateSubdirectories(
                rootDirectory: directory,
                extensions: config.imageExtensions,
                maxDepth: depth,
                size: size
            )
            status.show("Cached thumbnails for \(count) subdirectory image(s)")
        }
    }

    func deleteExifDateFromSelection() {
        exifOperations.deleteExifDateFromSelection()
    }

    func browseTrashImages() {
        let images = TrashDirectoryService.collectTrashImagePaths(extensions: config.imageExtensions)
        guard !images.isEmpty else {
            status.show("No image files found in Trash")
            return
        }
        directoryHistory.saveCurrent(fileData: fileData, config: config, selection: selection)
        setSpecificFilesActive(true)
        fileData.setDisplayedImages(images)
        fileData.setCurrentIndex(0)
        fileData.setCurrentImagePath(images[0])
        fileData.setViewMode(.thumbnail)
        status.show("Viewing \(images.count) image(s) from Trash")
        menuRefresh.refreshAll()
    }

    func beginRename(path: String) {
        if fileData.currentViewMode == .thumbnail, let grid = thumbnailGridHost {
            grid.beginInlineRename(path: path)
        } else {
            fileOperations.beginRename(path: path)
        }
    }

    func refreshMenuState() {
        menuRefresh.refreshAll()
    }

    func isFormattedListMode() -> Bool {
        let mode = SortMode(rawValue: config.string(forKey: "sort_mode", default: "date")) ?? .date
        return mode == .exifDate || mode == .exifYear || mode == .duplicates
    }

    func addDeletedPlaceholders(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        deletedFilePlaceholders.formUnion(paths)
        eventBus.emit(.deletedPlaceholdersChanged)
    }

    func clearDeletedPlaceholders() {
        guard !deletedFilePlaceholders.isEmpty else { return }
        deletedFilePlaceholders.removeAll()
        eventBus.emit(.deletedPlaceholdersChanged)
    }

    func clearDeletedPlaceholders(for paths: [String]) {
        guard !paths.isEmpty else { return }
        var changed = false
        for path in paths {
            if deletedFilePlaceholders.remove(path) != nil {
                changed = true
            }
        }
        if changed {
            eventBus.emit(.deletedPlaceholdersChanged)
        }
    }

    func isDeletedPlaceholder(path: String) -> Bool {
        deletedFilePlaceholders.contains(path) && !FileManager.default.fileExists(atPath: path)
    }

    func toggleRenameStatusChecking() {
        renameStatusManager.toggle()
        if renameStatusManager.isEnabled {
            let visible = rootDirectoryPaths()
            renameStatusManager.scanVisibleDirectories(visible, config: config)
            fileTreeReloadToken += 1
            status.show("Rename status checking enabled")
        } else {
            fileTreeReloadToken += 1
            status.show("Rename status checking disabled")
        }
    }

    private func rootDirectoryPaths() -> [String] {
        config.rootDirectories().compactMap { path in
            let expanded = (path as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }
            return expanded
        }
    }

    func showImageInDirectory() {
        let paths = selectedImagePaths()
        guard !paths.isEmpty else {
            status.show("No image selected")
            return
        }

        let directories = Set(paths.map { ($0 as NSString).deletingLastPathComponent })
        if directories.count > 1 {
            StyledMessageDialog.showWarning(
                title: "Multiple Directories",
                message: "Selected files belong to different directories. Choose files from one folder."
            )
            return
        }
        guard let directory = directories.first else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return
        }

        let savedSelection = Set(paths)
        config.updateSetting("sort_mode", value: SortMode.name.rawValue)
        config.updateSetting("sort_reversed", value: false)
        loadDirectory(directory, saveHistory: true)

        let displayed = Set(fileData.displayedImages)
        let restored = savedSelection.filter { displayed.contains($0) }
        if restored.count > 1 {
            selection.selectedFiles = restored
            selection.emitSelectionChanged(highlightIndex: fileData.currentIndex)
        }
        if let focus = paths.first(where: { fileData.displayedImages.contains($0) }) {
            fileData.setCurrentImagePath(focus)
        }
        fileData.setViewMode(.thumbnail)
        status.show("Showing image in directory")
    }


    private func selectedImagePaths() -> [String] {
        if !selection.selectedFiles.isEmpty {
            return Array(selection.selectedFiles)
        }
        if let current = fileData.currentImagePath {
            return [current]
        }
        return []
    }

    var isDirectoryRefreshSuppressed: Bool {
        if let until = suppressDirectoryRefreshUntil {
            return Date() < until
        }
        return false
    }

    func beginSuppressDirectoryRefresh() {
        suppressDirectoryRefreshUntil = Date().addingTimeInterval(0.6)
    }

    func endSuppressDirectoryRefresh() {
        suppressDirectoryRefreshUntil = Date().addingTimeInterval(0.6)
    }



    func toggleDebugMode() {
        let enabled = !config.bool(forKey: "debug_mode")
        config.applyLaunchDebugFlag(enabled)
        KeyboardInputTracer.installIfNeeded(config: config)
        status.show(enabled ? "Debug mode enabled" : "Debug mode disabled")
    }

    func printCacheStatus() {
        Task {
            let thumbStats = await thumbnailCache.statistics()
            let metaCount = metadataCache.entryCount
            let message = "Cache: \(thumbStats.diskCount) thumbnails on disk, "
                + "\(thumbStats.memoryCount) in memory, \(metaCount) metadata entries"
            status.show(message)
        }
    }

    func loadRandomImagesFromRecents(count: Int = 200) {
        let recent = config.recentDirectories(limit: 20)
        let searchDirs = uniqueTopLevelDirectories(from: recent, limit: 5)
        guard !searchDirs.isEmpty else {
            status.show("No recent directories available")
            return
        }
        status.show("Collecting images from recent directories…")
        Task {
            var files: [String] = []
            let extensions = Set(config.imageExtensions)
            for directory in searchDirs {
                guard let enumerator = FileManager.default.enumerator(
                    at: URL(fileURLWithPath: directory),
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for case let url as URL in enumerator {
                    let ext = url.pathExtension.lowercased()
                    if extensions.contains(ext) {
                        files.append(url.path)
                    }
                }
            }
            guard !files.isEmpty else {
                status.show("No images found in recent directories")
                return
            }
            let selected = Array(files.shuffled().prefix(min(count, files.count)))
            openPaths(selected)
            setSpecificFilesActive(true)
            status.show("Loaded \(selected.count) random images")
        }
    }

    func openLiveLog() {
        let logPath = config.logsDirectory
            .appendingPathComponent("image_browser_print_\(getuid()).log")
        if FileManager.default.fileExists(atPath: logPath.path) {
            NSWorkspace.shared.open(logPath)
        } else {
            StyledMessageDialog.showWarning(
                title: "Log file not found",
                message: logPath.path
            )
        }
    }

    func showAboutDialog() {
        aboutDialog.show(appState: self)
    }

    func closeAboutDialog() {
        aboutDialog.close()
    }



    private func uniqueTopLevelDirectories(from paths: [String], limit: Int) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for path in paths {
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: normalized) else { continue }
            let top = normalized.split(separator: "/").prefix(3).joined(separator: "/")
            let key = top.isEmpty ? normalized : "/" + top
            if seen.insert(key).inserted {
                result.append(normalized)
            }
            if result.count >= limit { break }
        }
        return result
    }


    private func startNamedPipeListener() {
        let listener = NamedPipeListener(pipePath: config.namedPipePath)
        listener.onMessage = { [weak self] message in
            self?.handlePipeMessage(message)
        }
        listener.start()
        pipeListener = listener
    }

    private func handlePipeMessage(_ message: [String: Any]) {
        if let type = message["type"] as? String {
            switch type {
            case "open", "load":
                if let paths = message["paths"] as? [String] {
                    openPaths(paths)
                } else if let files = message["files"] as? [String] {
                    openPaths(files)
                }
            case "activate":
                NSApp.activate(ignoringOtherApps: true)
            default:
                break
            }
        }
        if let files = message["files"] as? [String] {
            openPaths(files)
        }
        if let directory = message["directory"] as? String {
            loadDirectory(directory)
        }
    }

    func openPaths(_ paths: [String]) {
        directoryLoader.open(paths: paths)
    }


    /// Rebind CNN/CLIP caches and loaded Core ML models to current settings (no app restart).
    func refreshImageRecognitionForCurrentSettings() {
        imageRecognition.rebind(config: config)
        backgroundImageRecognition.noteSearchModelsChanged()
    }

    func loadDirectory(_ path: String, saveHistory: Bool = true) {
        setSpecificFilesActive(false)
        clearDeletedPlaceholders()
        backgroundImageRecognition.notePriorityDirectory(path)
        directoryLoader.loadDirectory(path, saveHistory: saveHistory)
        menuRefresh.refreshAll()
    }

    /// Tools ▸ Open Home Directory (Python `open_home_directory`, ⌃H / Qt `Meta+H`).
    func openHomeDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard FileManager.default.fileExists(atPath: home) else { return }
        if fileData.currentViewMode == .browse {
            closeBrowseView()
        }
        let hadFilter = filterSettings.filterPattern != "*"
        if hadFilter {
            filterSettings.setFilterPattern("*", persist: true)
            status.show("New directory opened, filter cleared")
        }
        loadDirectory(home, saveHistory: true)
    }

    /// After browse, align `currentDirectory` with the active image so the file tree can highlight correctly.
    func ensureCurrentDirectoryAlignedWithActiveImage() {
        guard let path = fileData.currentImagePath,
              FileManager.default.fileExists(atPath: path) else { return }
        if specificFilesActive || referenceGraphActive {
            return
        }
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
        if let current = fileData.currentDirectory,
           Self.directoryPathsMatch(current, dir) {
            return
        }
        loadDirectory(dir, saveHistory: false)
        if let normalized = FileDataModel.normalizePath(path) {
            fileData.setCurrentImagePath(normalized)
            DisplayedImagesSync.ensureActiveImageListed(
                fileData: fileData,
                filterPattern: filterSettings.filterPattern
            )
        }
    }

    func goBack() {
        directoryLoader.goBack()
    }

    func goForward() {
        directoryLoader.goForward()
    }

    func refreshDirectory() {
        guard let dir = fileData.currentDirectory else { return }
        let previous = fileData.displayedImages
        loadDirectory(dir, saveHistory: false)
        if fileData.displayedImages == previous {
            DirectoryRefreshService.invalidateThumbnails(appState: self, paths: previous)
        }
    }

    func watchCurrentDirectory() {
        if DirectoryRefreshService.shouldWatchDirectory(appState: self) {
            directoryWatcher.watch(directory: fileData.currentDirectory)
        } else {
            directoryWatcher.stop()
        }
    }

    func setSpecificFilesActive(_ active: Bool) {
        guard specificFilesActive != active else { return }
        specificFilesActive = active
        if !active {
            clearReferenceGraphPresentation()
        }
        watchCurrentDirectory()
    }

    private static func directoryPathsMatch(_ left: String, _ right: String) -> Bool {
        URL(fileURLWithPath: left).standardizedFileURL.path
            == URL(fileURLWithPath: right).standardizedFileURL.path
    }

    /// Force the browse canvas to reload when a file is overwritten at the same path.
    func reloadBrowseImageIfCurrent(path: String) {
        guard fileData.currentViewMode == .browse else { return }
        guard let normalized = FileDataModel.normalizePath(path) else { return }
        guard normalized == fileData.currentImagePath else { return }
        browseImageContentRevision += 1
    }

    /// Python `toggle_thumbnail_filename_overlay` (thumbnail/list) or browse `ctrl_i` number overlay.
    func cycleThumbnailOverlay() {
        if fileData.currentViewMode == .browse {
            toggleNumberOverlay()
            return
        }

        let currentFilename = config.bool(forKey: "thumbnail_filename_visible", default: false)
        let currentSize = config.bool(forKey: "show_image_size", default: false)
        let newFilename: Bool
        let newSize: Bool
        if !currentFilename, !currentSize {
            (newFilename, newSize) = (true, false)
        } else if currentFilename, !currentSize {
            (newFilename, newSize) = (false, true)
        } else if !currentFilename, currentSize {
            (newFilename, newSize) = (true, true)
        } else {
            (newFilename, newSize) = (false, false)
        }
        config.updateSetting("thumbnail_filename_visible", value: newFilename)
        config.updateSetting("show_image_size", value: newSize)
        config.applySettingsChange(emit: eventBus)
        let label: String
        switch (newFilename, newSize) {
        case (false, false): label = "Thumbnail overlay: off"
        case (true, false): label = "Thumbnail overlay: name"
        case (false, true): label = "Thumbnail overlay: size"
        default: label = "Thumbnail overlay: name and size"
        }
        status.show(label)
    }


    func toggleFileTree() {
        let wasVisible = config.bool(forKey: "file_tree_visible", default: true)
        setLeftSidebarPaneVisible(
            configKey: "file_tree_visible",
            visible: !wasVisible
        )
        if !wasVisible {
            revealFileTreeFocusedOnActiveImage()
        }
    }

    func showFileTree() {
        let wasVisible = config.bool(forKey: "file_tree_visible", default: true)
        guard !wasVisible else {
            revealFileTreeFocusedOnActiveImage()
            return
        }
        setLeftSidebarPaneVisible(configKey: "file_tree_visible", visible: true)
        revealFileTreeFocusedOnActiveImage()
    }

    /// Expand/select the tree row for the active image directory without moving keyboard focus.
    func syncFileTreeToActiveImage() {
        fileTreeSyncActiveImageToken += 1
    }

    /// Show/focus file tree on the active image directory (Python tree show + `highlight_current_file`).
    func revealFileTreeFocusedOnActiveImage() {
        syncFileTreeToActiveImage()
        requestFileTreeFocus()
    }

    func requestFileTreeFocus() {
        fileTreeFocusToken += 1
    }

    func noteUserRequestedTreeDirectory(_ path: String) {
        userRequestedTreeDirectory = FileTreeFilter.standardizedPath(path)
        userRequestedTreeClearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.userRequestedTreeDirectory = nil
        }
        userRequestedTreeClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    func clearUserRequestedTreeDirectory() {
        userRequestedTreeDirectory = nil
        userRequestedTreeClearWork?.cancel()
        userRequestedTreeClearWork = nil
    }

    func collapseFileTreeToHome() {
        fileTreeCollapseUIToken += 1
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        loadDirectory(home, saveHistory: true)
    }

    /// ⌘Return — collapse tree UI and highlight home (Python `collapse_file_tree`).
    func collapseFileTree() {
        fileTreeCollapseUIToken += 1
    }

    /// ⌘⇧Return — expand tree to the current directory.
    func expandFileTreeToCurrentDirectory() {
        fileTreeExpandToken += 1
    }

    func clearDirectoryHistory() {
        let cleared = directoryHistory.clearAll()
        if cleared > 0 {
            status.show("Cleared \(cleared) history entries")
        } else {
            status.show("History stacks already empty")
        }
    }

    func toggleListView() {
        if fileData.currentViewMode == .list {
            fileData.setViewMode(.thumbnail)
        } else {
            fileData.setViewMode(.list)
        }
    }

    func adjustListRowHeight(delta: Int) {
        let current = config.int(forKey: "list_view_row_height", default: 48)
        let next = min(64, max(28, current + delta))
        config.updateSetting("list_view_row_height", value: next)
        config.applySettingsChange(emit: eventBus)
        status.show("List row height: \(next)px")
    }

    func resetListRowHeight() {
        config.updateSetting("list_view_row_height", value: 48)
        config.applySettingsChange(emit: eventBus)
        status.show("List row height reset")
    }

    var informationHasUserComment: Bool {
        guard let path = fileData.currentImagePath else { return false }
        let comment = ExifService.userComment(path: path) ?? ""
        return !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func openSettingsWindow(tab explicitTab: SettingsTab? = nil, userInfo: [String: Any] = [:]) {
        let tab = SettingsTab.resolvedOpenTab(explicit: explicitTab)
        requestedSettingsTab = tab
        var info = userInfo
        info["tab"] = tab.rawValue
        NotificationCenter.default.post(
            name: .prowserOpenSettingsTab,
            object: nil,
            userInfo: info
        )
        settingsOpenRequestToken += 1
        settingsDialog.show(appState: self)
    }

    func userCommentForActiveImage() -> String? {
        guard let path = fileData.currentImagePath else { return nil }
        let comment = ExifService.userComment(path: path) ?? ""
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func userCommentForActiveImageAsync() async -> String? {
        guard let path = fileData.currentImagePath else { return nil }
        let comment = await ExifService.userDescription(path: path) ?? ""
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Prompt-only text for image-gen priming (Python `_user_comment_for_active_image` → `_dialog_initial_prompt_from_user_comment`).
    func importPromptForActiveImageAsync() async -> String? {
        guard let path = fileData.currentImagePath,
              FileManager.default.isReadableFile(atPath: path) else { return nil }
        return await ExifService.importPromptFromPath(path)
    }

    func beginEditUserComment() {
        guard let path = resolveUserCommentEditPath() else {
            status.show("No image selected")
            return
        }
        guard FileManager.default.fileExists(atPath: path) else {
            status.show("No image selected")
            return
        }
        guard ExifService.canWriteExif(path: path) else {
            StyledMessageDialog.showWarning(
                title: "This file format does not support EXIF User Comment editing.",
                message: ""
            )
            return
        }
        editUserCommentPath = path
        editUserCommentError = nil
        Task {
            let text = await ExifService.userDescription(path: path) ?? ""
            editUserCommentText = text
            editUserCommentOriginalText = text
            let alreadyOpen = showEditUserCommentSheet
            showEditUserCommentSheet = true
            if alreadyOpen {
                auxiliaryDialogs.bringToFront(Self.DialogID.editExifUserComment)
            }
        }
    }

    func saveEditUserComment() {
        guard let path = editUserCommentPath else { return }
        Task {
            do {
                try await ExifService.writeUserComment(path: path, text: editUserCommentText)
                cancelEditUserComment()
                metadataCache.invalidate(path: path)
                refreshDirectory()
            } catch {
                StyledMessageDialog.showWarning(
                    title: "EXIF Error",
                    message: error.localizedDescription
                )
            }
        }
    }

    func cancelEditUserComment() {
        showEditUserCommentSheet = false
        editUserCommentPath = nil
        editUserCommentOriginalText = ""
        editUserCommentText = ""
        editUserCommentError = nil
    }

    func openImageInBrowse(path: String, saveHistory: Bool = true) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        if directory != fileData.currentDirectory {
            loadDirectory(directory, saveHistory: saveHistory)
        }
        fileData.setCurrentImagePath(path)
        DisplayedImagesSync.ensureActiveImageListed(
            fileData: fileData,
            filterPattern: filterSettings.filterPattern
        )
        if let normalized = FileDataModel.normalizePath(path),
           let index = fileData.displayedImages.firstIndex(of: normalized) {
            fileData.setCurrentIndex(index)
        }
        fileData.setViewMode(.browse)
    }

    private func resolveUserCommentEditPath() -> String? {
        switch fileData.currentViewMode {
        case .browse:
            return fileData.currentImagePath
        case .thumbnail, .list:
            let selected = Array(selection.selectedFiles)
            if selected.count == 1 {
                return selected[0]
            }
            return fileData.currentImagePath
        default:
            return nil
        }
    }

    /// Python File → Exit (⌘Q / `QAction.QuitRole`) is connected to `main_window.close`.
    func closeMainWindow() {
        WindowFullscreen.noteMainWindowClosing()
        quitConfirmedViaClose = true
        let mainWindows = NSApp.windows.filter(Self.isPrimaryBrowserWindow)
        if let window = mainWindows.first(where: { $0 === NSApp.keyWindow }) ?? mainWindows.first {
            window.performClose(nil)
        }
        // Extra SwiftUI scenes (Settings) can keep the process alive after the
        // browser window closes; terminate so Exit/⌘Q still quits.
        NSApp.terminate(nil)
    }

    private static func isPrimaryBrowserWindow(_ window: NSWindow) -> Bool {
        BrowserWindowIdentity.isMainBrowserWindow(window)
    }

    enum DialogID {
        static let editExifUserComment = "editExifUserComment"
        static let keyboardHelp = "keyboardHelp"
        static let convertFormat = "convertFormat"
        static let resizeImages = "resizeImages"
        static let renamePrefix = "renamePrefix"
        static let findReferences = "findReferences"
        static let referenceGraph = "referenceGraph"
        static let exifBatchConfirmation = "exifBatchConfirmation"
        static let filter = "filter"
        static let moveWorkFiles = "moveWorkFiles"
        static let similaritySearch = "similaritySearch"
        static let clipSearch = "clipSearch"
        static let imageRecognitionCaveats = "imageRecognitionCaveats"
    }

    func syncAuxiliaryDialogs() {
        syncDialog(
            id: DialogID.editExifUserComment,
            show: showEditUserCommentSheet,
            title: "Edit EXIF User Comment",
            defaultSize: NSSize(width: 520, height: 420),
            minSize: NSSize(width: 480, height: 320),
            focusTextOnShow: true,
            onClose: { [weak self] in self?.cancelEditUserComment() }
        ) {
            EditExifUserCommentSheet()
        }
        syncDialog(
            id: DialogID.keyboardHelp,
            show: showKeyboardHelp,
            title: "Keyboard Shortcuts",
            defaultSize: NSSize(width: 520, height: 520),
            minSize: NSSize(width: 480, height: 400),
            onClose: { [weak self] in self?.showKeyboardHelp = false }
        ) {
            KeyboardShortcutsHelpView()
        }
        syncDialog(
            id: DialogID.convertFormat,
            show: showConvertFormatSheet,
            title: "Convert Image Format",
            defaultSize: NSSize(width: 380, height: 220),
            minSize: NSSize(width: 320, height: 180),
            onClose: { [weak self] in self?.showConvertFormatSheet = false }
        ) {
            ConvertFormatSheet()
        }
        syncDialog(
            id: DialogID.resizeImages,
            show: showResizeSheet,
            title: "Resize Images",
            defaultSize: NSSize(width: 420, height: 480),
            minSize: NSSize(width: 360, height: 360),
            onClose: { [weak self] in self?.showResizeSheet = false }
        ) {
            ResizeImagesSheet()
        }
        syncDialog(
            id: DialogID.renamePrefix,
            show: renamePrefixDialog != nil,
            title: "Rename with Custom Prefix",
            defaultSize: NSSize(width: 560, height: 330),
            minSize: NSSize(width: 520, height: 300),
            onClose: { [weak self] in
                guard let self, self.renamePrefixDialog != nil else { return }
                self.renamePrefixDialog = nil
                self.renamePrefixService.dialogFinished(nil)
            }
        ) {
            if let request = renamePrefixDialog {
                RenamePrefixSheet(request: request)
            }
        }
        syncDialog(
            id: DialogID.findReferences,
            show: showFindReferencesSheet,
            title: "Find References",
            defaultSize: NSSize(width: 560, height: 420),
            minSize: NSSize(width: 520, height: 380),
            onClose: { [weak self] in self?.showFindReferencesSheet = false }
        ) {
            FindReferencesSheet()
        }
        syncDialog(
            id: DialogID.referenceGraph,
            show: showReferenceGraphSheet && referenceGraphData != nil,
            title: "Reference Graph",
            defaultSize: NSSize(width: 560, height: 460),
            minSize: NSSize(width: 520, height: 400),
            onClose: { [weak self] in self?.showReferenceGraphSheet = false }
        ) {
            if let graph = referenceGraphData {
                ReferenceGraphView(graph: graph)
            }
        }
        syncDialog(
            id: DialogID.exifBatchConfirmation,
            show: exifBatchConfirmation != nil,
            title: exifBatchConfirmation?.title ?? "Confirm EXIF Change",
            defaultSize: NSSize(width: 560, height: 460),
            minSize: NSSize(width: 520, height: 420),
            onClose: { [weak self] in self?.exifBatchConfirmation = nil }
        ) {
            if let state = exifBatchConfirmation {
                ExifBatchConfirmationSheet(state: state) { [weak self] in
                    self?.exifBatchConfirmation = nil
                }
            }
        }
        syncDialog(
            id: DialogID.filter,
            show: showFilterDialog,
            title: "Edit Filters",
            defaultSize: NSSize(width: 360, height: 400),
            minSize: NSSize(width: 320, height: 360),
            focusTextOnShow: true,
            onClose: { [weak self] in self?.showFilterDialog = false }
        ) {
            FilterDialogSheet()
        }
        syncDialog(
            id: DialogID.moveWorkFiles,
            show: showMoveWorkFilesSheet,
            title: "Move Work Files",
            defaultSize: NSSize(width: 420, height: 180),
            minSize: NSSize(width: 360, height: 160),
            focusTextOnShow: true,
            onClose: { [weak self] in self?.showMoveWorkFilesSheet = false }
        ) {
            MoveWorkFilesSheet()
        }
        syncDialog(
            id: DialogID.similaritySearch,
            show: showSimilaritySearchSheet,
            title: "Find Similar Images",
            defaultSize: NSSize(width: 480, height: 260),
            minSize: NSSize(width: 440, height: 220),
            focusTextOnShow: true,
            onClose: { [weak self] in self?.showSimilaritySearchSheet = false }
        ) {
            SimilaritySearchSheet { [weak self] options in
                self?.searchOperations.runSimilaritySearch(options: options)
            }
        }
        syncDialog(
            id: DialogID.clipSearch,
            show: showClipSearchSheet,
            title: "Search by Text",
            defaultSize: NSSize(width: 500, height: 320),
            minSize: NSSize(width: 460, height: 280),
            focusTextOnShow: true,
            onClose: { [weak self] in self?.showClipSearchSheet = false }
        ) {
            ClipSearchSheet { [weak self] options in
                self?.searchOperations.runClipSearch(options: options)
            }
        }
        syncDialog(
            id: DialogID.imageRecognitionCaveats,
            show: showImageRecognitionCaveats,
            title: "Image Search (Native)",
            defaultSize: NSSize(width: 560, height: 480),
            minSize: NSSize(width: 520, height: 420),
            onClose: { [weak self] in self?.showImageRecognitionCaveats = false }
        ) {
            ImageRecognitionCaveatsView()
        }
    }

    private func syncDialog<Content: View>(
        id: String,
        show: Bool,
        title: String,
        defaultSize: NSSize,
        minSize: NSSize,
        focusTextOnShow: Bool = false,
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        if show {
            guard !auxiliaryDialogs.isVisible(id) else { return }
            auxiliaryDialogs.present(
                id: id,
                title: title,
                appState: self,
                defaultSize: defaultSize,
                minSize: minSize,
                focusTextOnShow: focusTextOnShow,
                content: content(),
                onClose: onClose
            )
        } else {
            auxiliaryDialogs.close(id)
        }
    }

    func confirmQuitIfRunning() -> Bool {
        true
    }

    func prepareForApplicationExit() {
        auxiliaryDialogs.closeAll()
    }


    func setOuterSidebarVisible(side: SidebarSplitSide, visible: Bool) {
        clearChromeSuppression()
        switch side {
        case .left:
            config.updateSetting("left_sidebar_visible", value: visible)
        case .right:
            config.updateSetting("right_sidebar_visible", value: visible)
        }
        noteSidebarLayoutChanged()
    }

    func togglePreviewPane() {
        setLeftSidebarPaneVisible(
            configKey: "preview_visible",
            visible: !config.bool(forKey: "preview_visible", default: true)
        )
    }

    func showPreviewPane() {
        guard !config.bool(forKey: "preview_visible", default: true) else { return }
        setLeftSidebarPaneVisible(configKey: "preview_visible", visible: true)
    }

    /// Port of `combined_sidebar_widget._needed_pane_height(1)` content part (title double-click fit).
    func previewPanePreferredContentHeight() -> CGFloat {
        previewPaneCache.preferredContentHeight(for: fileData.currentImagePath, clientWidth: leftSidebarWidth)
    }

    func openMapForCurrentImage() {
        let paths: [String]
        if !selection.selectedFiles.isEmpty {
            paths = Array(selection.selectedFiles)
        } else if let current = fileData.currentImagePath {
            paths = [current]
        } else {
            showMapAlert(title: "No Image Selected", message: "Please select an image first.")
            return
        }

        let preferred = config.string(forKey: "map_application", default: "apple_maps")
        switch MapService.openMap(
            for: paths,
            preferredApp: preferred,
            temporaryDirectory: config.temporaryFilesDirectory
        ) {
        case .success:
            status.show("Opened map for GPS location")
        case .failure(.noGPSData(let message)):
            showMapAlert(title: "No GPS Data", message: message)
        case .failure(.noImages):
            showMapAlert(title: "No Image Selected", message: "Please select an image first.")
        case .failure(.openFailed(let message)):
            showMapAlert(title: "Map Error", message: message)
        }
    }

    func openFileDialog() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.prompt = "Open"
        guard panel.runModal() == .OK else { return }

        let paths = panel.urls.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return }

        directoryHistory.saveCurrent(fileData: fileData, config: config, selection: selection)
        if fileData.currentViewMode == .browse {
            fileData.setViewMode(.thumbnail)
        }

        let hadFilter = filterSettings.filterPattern != "*"
        if hadFilter {
            filterSettings.setFilterPattern("*", persist: true)
        }

        if paths.count > 1 {
            let normalized = paths.compactMap { FileDataModel.normalizePath($0) }
            guard !normalized.isEmpty else { return }

            config.updateSetting("sort_mode", value: SortMode.custom.rawValue)
            config.updateSetting("sort_reversed", value: false)
            let directory = URL(fileURLWithPath: normalized[0]).deletingLastPathComponent().path
            setSpecificFilesActive(true)
            fileData.setCurrentDirectory(directory)
            fileData.setDisplayedImages(normalized)
            fileData.setCurrentIndex(0)
            fileData.setCurrentImagePath(normalized[0])
            config.updateSetting("last_directory", value: directory)
            eventBus.emit(.directoryLoaded, payload: .string(directory))
            watchCurrentDirectory()
            selection.clear()
            status.show(hadFilter ? "Opened \(normalized.count) files, filter cleared" : "Opened \(normalized.count) files")
            return
        }

        let filePath = paths[0]
        let directory = (filePath as NSString).deletingLastPathComponent
        setSpecificFilesActive(false)
        config.updateSetting("sort_mode", value: SortMode.name.rawValue)
        config.updateSetting("sort_reversed", value: false)
        loadDirectory(directory, saveHistory: false)
        fileData.setCurrentImagePath(filePath)
        DisplayedImagesSync.ensureActiveImageListed(
            fileData: fileData,
            filterPattern: filterSettings.filterPattern
        )
        fileData.setViewMode(.thumbnail)
        status.show(hadFilter ? "Opened file, filter cleared" : "Opened file")
    }

    private func showMapAlert(title: String, message: String) {
        StyledMessageDialog.showWarning(title: title, message: message)
    }


    func toggleNumberOverlay() {
        numberOverlayVisible.toggle()
        if fileData.currentViewMode == .browse {
            status.show(numberOverlayVisible ? "Browse overlay: on" : "Browse overlay: off")
        }
    }

    func toggleBrowseActualSize() {
        guard fileData.currentViewMode == .browse else { return }
        let enabled = !config.bool(forKey: "browse_view_actual_size", default: false)
        config.updateSetting("browse_view_actual_size", value: enabled)
        eventBus.emit(.browseKeyboard, payload: .browseAction(.setActualSize(enabled)))
        status.show(enabled ? "Actual size mode" : "Fit to window mode")
    }

    var browseActualSizeEnabled: Bool {
        config.bool(forKey: "browse_view_actual_size", default: false)
    }

    func createScreenSizeCopy(fitMethod: ScreenSizeCopyService.FitMethod? = nil) {
        let paths = selectedImagePaths()
        guard !paths.isEmpty else {
            status.show("No files selected")
            return
        }

        let method = fitMethod ?? ScreenSizeCopyService.FitMethod(
            configValue: config.string(forKey: "last_used_screen_copy_fit_method", default: "cover")
        )
        let borders = config.bool(forKey: "screen_copy_borders_on_copy", default: true)
        let preserveDates = config.bool(forKey: "screen_copy_preserve_dates", default: true)
        config.updateSetting("last_used_screen_copy_fit_method", value: method.rawValue)

        if paths.count > 1 {
            guard StyledMessageDialog.showConfirm(
                title: "Create screen size copy?",
                message: "Create screen-sized copies for \(paths.count) files?",
                confirmTitle: "Create"
            ) else { return }
        }

        var created = 0
        var lastError: String?
        for path in paths {
            do {
                _ = try ScreenSizeCopyService.createCopy(
                    path: path,
                    fitMethod: method,
                    bordersOnCopy: borders,
                    preserveDates: preserveDates
                )
                created += 1
            } catch {
                lastError = error.localizedDescription
            }
        }

        if created > 0 {
            status.show(
                created == 1
                    ? "Created screen-sized copy"
                    : "Created \(created) screen-sized copies"
            )
            refreshDirectory()
        } else {
            StyledMessageDialog.showWarning(
                title: "Screen size copy failed",
                message: lastError ?? "No files were processed."
            )
        }
    }

    func adjustThumbnailCellSize(multiplier: Double) {
        let current = config.double(forKey: "thumbnail_cell_size", default: ThumbnailLayout.defaultCellSize)
        let newSize = min(
            ThumbnailLayout.maxCellSize,
            max(ThumbnailLayout.minCellSize, current * multiplier)
        )
        config.updateSetting("thumbnail_cell_size", value: newSize)
        config.updateSetting("manual_thumbnail_size", value: true)
        config.applySettingsChange(emit: eventBus)
        status.show(String(format: "Thumbnail size: %.0f", newSize))
    }

    func resetThumbnailCellSize() {
        config.updateSetting("manual_thumbnail_size", value: false)
        config.updateSetting("thumbnail_cell_size", value: ThumbnailLayout.defaultCellSize)
        config.applySettingsChange(emit: eventBus)
        status.show("Thumbnail size reset")
    }

}

/// Last drop is session-only (Python `FileTree._last_drop_location`); strip any saved copy.
@MainActor
private func discardPersistedLastDropLocation(config: AppConfig) {
    guard config.rawSettings()["last_drop_location"] != nil else { return }
    config.updateSetting("last_drop_location", value: nil)
}

/// One-time fixes when moving from Python profile settings to Swift UI.
@MainActor
private func migrateSwiftSidebarDefaults(config: AppConfig) {
    guard config.rawSettings()["prowser_swift_migrated_file_tree"] == nil else { return }
    if config.rawSettings()["file_tree_visible"] as? Bool == false {
        config.updateSetting("file_tree_visible", value: true)
    }
    config.updateSetting("prowser_swift_migrated_file_tree", value: true)
}
