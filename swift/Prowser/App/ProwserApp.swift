import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct ProwserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Prowser", id: "main") {
            PrimaryOrSecondaryRoot(isPrimary: appDelegate.isPrimary, appState: appDelegate.appState)
        }
        .defaultSize(width: 1280, height: 840)
        .commands {
            if let appState = appDelegate.appState, appDelegate.isPrimary {
                ProwserCommands(appState: appState)
            }
        }
    }
}

/// Snapshot of pane/status visibility for F4 / `.` chrome toggle (Python `_chrome_saved_layout`).
struct ChromeSavedLayout: Equatable {
    var statusBarVisible: Bool
    var fileTreeVisible: Bool
    var previewVisible: Bool
    var chatVisible: Bool
    var shortcutsVisible: Bool
    var informationVisible: Bool
    var leftSidebarVisible: Bool
    var rightSidebarVisible: Bool
    var leftSidebarWidth: CGFloat
    var rightSidebarWidth: CGFloat
    var leftSplitterSizes: [CGFloat]
    var rightSplitterSizes: [CGFloat]
}

/// Shared application state container (models + config).
@Observable
@MainActor
final class AppState {
    let config: AppConfig
    let fileData = FileDataModel()
    let selection = SelectionModel()
    let filterSettings = FilterSettingsModel(config: nil)
    let eventBus = AppEventBus()
    let thumbnailCache: ThumbnailCache
    let metadataCache: MetadataCacheService
    let previewPaneCache = PreviewPaneSessionCache()
    let fileOperations: FileOperationsService
    let exifOperations = ExifOperationsController()
    let searchOperations = SearchOperationsService()
    let fileTreeOperations = FileTreeOperationsService()
    let renamePrefixService = RenamePrefixService()
    let status = StatusNotificationService()
    private let keyboardHandler = KeyboardHandlerController()
    private let statusBarPeekMonitor = StatusBarPeekMonitor()
    private let aboutDialog = AboutDialogController()
    private let settingsDialog = SettingsDialogController()
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
    private var userRequestedTreeClearWork: DispatchWorkItem?
    var settingsOpenRequestToken = 0
    var requestedSettingsTab: SettingsTab = .general
    var showKeyboardHelp = false
    var isAboutDialogVisible: Bool { aboutDialog.isVisible }
    var isSettingsDialogVisible: Bool { settingsDialog.isVisible }
    var showFindReferencesSheet = false
    var showReferenceGraphSheet = false
    var referenceGraphActive = false
    var referenceGraphFocusPath: String?
    var referenceGraphData: ReferenceGraph?
    var slideshow2ViewportSize = CGSize(width: 800, height: 600)
    var statusBarPeekActive = false
    private var browseReturnThumbnailState: BrowseReturnThumbnailState?
    private var lastViewMode: ViewMode = .thumbnail
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
    /// Bumped when on-disk image content changes so list/thumbnail views reload affected thumbs.
    var thumbnailInvalidationGeneration = 0
    /// Bumped when the active browse image file changes on disk at the same path.
    var browseImageContentRevision = 0
    var fileTreeCollapseUIToken = 0
    var fileTreeExpandToken = 0
    var fileTreeReloadToken = 0
    var fileOpsTargetPaths: [String] = []
    /// Paths deleted in formatted-list mode; slot preserved with red-X overlay (Python `deleted_file_placeholders`).
    var deletedFilePlaceholders: Set<String> = []
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
    private(set) var sidebarLayoutRevision = 0
    private var chromeSavedLayout: ChromeSavedLayout?
    private let directoryWatcher = DirectoryWatcher()
    private var pipeListener: NamedPipeListener?
    private var suppressDirectoryRefreshUntil: Date?

    let launchOptions: LaunchOptions
    private(set) var directoryLoader: DirectoryLoadCoordinator!

    init(launchOptions: LaunchOptions = LaunchOptions.parse()) {
        self.launchOptions = launchOptions
        let config = AppConfig(profilePath: launchOptions.profilePath)
        self.config = config
        filterSettings.bindConfig(config)

        if let pattern = launchOptions.filterPattern {
            filterSettings.setFilterPattern(pattern, persist: false)
        }

        config.loadSettings()
        migrateSwiftSidebarDefaults(config: config)
        leftSidebarSplit = SidebarPaneSplitModel(side: .left, config: config)
        rightSidebarSplit = SidebarPaneSplitModel(side: .right, config: config)
        leftSidebarWidth = SidebarWidthLimits.clampLeft(config.sidebarWidth)
        rightSidebarWidth = SidebarWidthLimits.clampRight(config.rightSidebarWidth)
        filterSettings.loadFromConfig()
        let profilePaths = ProfilePaths(profilePath: launchOptions.profilePath)
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

        NotificationCenter.default.addObserver(
            forName: .prowserCurrentImageChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let path = notification.object as? String
            Task { @MainActor in self.browseImageHistory.onCurrentImageChanged(path) }
        }
        NotificationCenter.default.addObserver(
            forName: .prowserViewModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.browseImageHistory.onViewModeChanged() }
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

    func decreaseSlideshowOverlap() {
        let transition = config.int(forKey: "slideshow_transition_speed", default: 1300)
        let current = config.int(forKey: "slideshow_overlap_delay", default: 0)
        let next = min(Int(Double(transition) * 1.0), current + Int(Double(transition) * 0.1))
        config.updateSetting("slideshow_overlap_delay", value: next)
        config.applySettingsChange(emit: eventBus)
        showSlideshowOverlapStatus(transition: transition, delay: next)
    }

    func increaseSlideshowOverlap() {
        let transition = config.int(forKey: "slideshow_transition_speed", default: 1300)
        let current = config.int(forKey: "slideshow_overlap_delay", default: 0)
        let next = max(-Int(Double(transition) * 0.3), current - Int(Double(transition) * 0.1))
        config.updateSetting("slideshow_overlap_delay", value: next)
        config.applySettingsChange(emit: eventBus)
        showSlideshowOverlapStatus(transition: transition, delay: next)
    }

    func applySlideshowPreset(_ key: String) {
        let preset = SlideshowPresetUtils.preset(from: config.rawSettings(), key: key)
        config.updateSetting("slideshow_rate", value: preset["rate"] as? Int ?? 3500)
        config.updateSetting("slideshow_transition_speed", value: preset["transition_speed"] as? Int ?? 1300)
        config.updateSetting("slideshow_max_rotation", value: preset["max_rotation"] as? Int ?? 0)
        config.updateSetting("slideshow_overlap_delay", value: preset["overlap_delay"] as? Int ?? 0)
        config.updateSetting("slideshow_direction", value: preset["direction"] as? String ?? "right")
        config.applySettingsChange(emit: eventBus)
        status.show(SlideshowPresetUtils.statusMessage(for: preset))
    }

    private func showSlideshowOverlapStatus(transition: Int, delay: Int) {
        let percent = SlideshowPresetUtils.overlapPercent(overlapDelay: delay, transitionSpeed: transition)
        if percent > 100 {
            status.show("Overlap: \(percent)% (incoming early)")
        } else {
            status.show("Overlap: \(percent)%")
        }
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

    /// Python ``InformationSidebar._on_anchor_clicked`` for ``reflevel://``.
    func handleInformationReferenceLevelClick(optionHeld: Bool) {
        guard let path = fileData.currentImagePath,
              FileManager.default.isReadableFile(atPath: path) else { return }
        Task { @MainActor in
            guard let comment = await ExifService.userDescription(path: path) else { return }
            let imageDir = (path as NSString).deletingLastPathComponent
            let entries = ReferenceGraphService.parseReferenceEntries(from: comment)
            guard !entries.isEmpty else { return }

            if optionHeld {
                let (paths, _, extensionSwapped) = ReferenceGraphService.resolveExifReferencePaths(
                    imageDir: imageDir,
                    currentPath: path,
                    entries: entries
                )
                guard !paths.isEmpty else { return }
                if extensionSwapped {
                    status.show(
                        "Some references were found with a different file extension",
                        duration: 5
                    )
                }
                openReferencePaths(paths, focusPath: path)
                return
            }

            let (paths, extensionSwapped) = await ReferenceGraphService.collectReferenceChainPaths(
                imageDir: imageDir,
                rootPath: path,
                entries: entries
            )
            guard paths.count >= 2 else { return }
            if extensionSwapped {
                status.show(
                    "Some references were found with a different file extension",
                    duration: 5
                )
            }
            await openReferenceGraphPresentation(
                paths: paths,
                focusPath: path,
                extensionSwapped: extensionSwapped
            )
        }
    }

    func showReferenceGraph(for path: String? = nil) {
        guard let imagePath = path ?? fileData.currentImagePath else { return }
        Task { @MainActor in
            await openReferenceGraph(for: imagePath)
        }
    }

    /// Python ``open_reference_graph_for_path``.
    func openReferenceGraph(for imagePath: String) async {
        guard FileManager.default.isReadableFile(atPath: imagePath) else { return }
        guard let comment = await ExifService.userDescription(path: imagePath) else {
            status.show("No EXIF user comment on this image")
            return
        }
        let imageDir = (imagePath as NSString).deletingLastPathComponent
        let entries = ReferenceGraphService.parseReferenceEntries(from: comment)
        guard !entries.isEmpty else {
            StyledMessageDialog.showInformation(
                title: "No References Found",
                message: """
                This image has no reference information in its EXIF user comment. \
                References are saved there by the image generation functions when \
                an image is created from other images.
                """
            )
            return
        }
        let (paths, extensionSwapped) = await ReferenceGraphService.collectReferenceChainPaths(
            imageDir: imageDir,
            rootPath: imagePath,
            entries: entries
        )
        guard paths.count >= 2 else {
            StyledMessageDialog.showInformation(
                title: "No References Found",
                message: """
                This image has no reference information in its EXIF user comment. \
                References are saved there by the image generation functions when \
                an image is created from other images.
                """
            )
            return
        }
        await openReferenceGraphPresentation(
            paths: paths,
            focusPath: imagePath,
            extensionSwapped: extensionSwapped
        )
    }

    func clearReferenceGraphPresentation() {
        referenceGraphActive = false
        referenceGraphData = nil
        referenceGraphFocusPath = nil
    }

    /// Python ``set_reference_graph_presentation``: build the DAG for a specific-files level.
    /// Focus falls back to the current image, then the first path, when not in the set.
    func setReferenceGraphPresentation(paths: [String], focusPath: String?) async {
        let normalized = paths.compactMap { FileDataModel.normalizePath($0) }
        guard normalized.count > 1 else {
            clearReferenceGraphPresentation()
            return
        }
        var focus = focusPath ?? fileData.currentImagePath ?? normalized[0]
        if let focusNorm = FileDataModel.normalizePath(focus), !normalized.contains(focusNorm) {
            focus = normalized[0]
        }
        let graph = await ReferenceGraphService.buildReferenceGraph(paths: normalized, focusPath: focus)
        referenceGraphActive = true
        referenceGraphData = graph
        referenceGraphFocusPath = graph.focusPath ?? focus
    }

    func openReferenceGraphPresentation(
        paths: [String],
        focusPath: String,
        extensionSwapped: Bool = false
    ) async {
        let normalized = paths.compactMap { FileDataModel.normalizePath($0) }
        guard normalized.count >= 2 else { return }
        if extensionSwapped {
            status.show(
                "Some references were found with a different file extension",
                duration: 5
            )
        }

        directoryHistory.saveCurrent(fileData: fileData, config: config, selection: selection)

        await setReferenceGraphPresentation(paths: normalized, focusPath: focusPath)

        config.updateSetting("sort_mode", value: SortMode.custom.rawValue)
        config.updateSetting("sort_reversed", value: false)
        let directory = URL(fileURLWithPath: normalized[0]).deletingLastPathComponent().path
        setSpecificFilesActive(true)
        fileData.setCurrentDirectory(directory)
        fileData.setDisplayedImages(normalized)
        if let focus = referenceGraphFocusPath,
           let index = normalized.firstIndex(where: {
               FileDataModel.normalizePath($0) == FileDataModel.normalizePath(focus)
           }) {
            fileData.setCurrentIndex(index)
            fileData.setCurrentImagePath(normalized[index])
        } else {
            fileData.setCurrentIndex(0)
            fileData.setCurrentImagePath(normalized[0])
        }
        if fileData.currentViewMode != .thumbnail {
            fileData.setViewMode(.thumbnail)
        }
        config.updateSetting("last_directory", value: directory)
        // Note: do not emit `.settingsChanged` here — its subscriber reloads the whole
        // directory, which would discard the specific-files reference level.
        eventBus.emit(.directoryLoaded, payload: .string(directory))
        watchCurrentDirectory()
        selection.clear()
        status.show("Reference graph: \(normalized.count) files")
    }

    func fitSlideshow2ToCanvasWidth() {
        guard fileData.currentViewMode == .slideshow2,
              let path = fileData.currentImagePath,
              let image = NSImage(contentsOfFile: path) else { return }
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let viewport = slideshow2ViewportSize
        guard viewport.width > 1, viewport.height > 1 else { return }

        let widthScale = (viewport.width * 1.5) / imageSize.width
        let heightScale = (viewport.height * 1.5) / imageSize.height
        let baseScale = max(widthScale, heightScale)
        guard baseScale > 0 else { return }

        let targetScale = viewport.width / imageSize.width
        let newEnlargement = min(3.0, max(0.5, targetScale / baseScale))
        config.updateSetting("slideshow2_enlargement", value: newEnlargement)
        config.applySettingsChange(emit: eventBus)
        status.show(String(format: "Panning zoom: %.1fx (fit width)", newEnlargement))
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

    func updateStatusBarPeek(nearBottom: Bool) {
        guard config.bool(forKey: "raise_status_bar_on_cursor_near_bottom", default: true) else { return }
        guard !chromeSuppressed else { return }
        let hidden = !config.bool(forKey: "status_bar_visible", default: true)
        guard hidden else {
            if statusBarPeekActive { statusBarPeekActive = false }
            return
        }
        if nearBottom && !statusBarPeekActive {
            statusBarPeekActive = true
            sidebarLayoutRevision += 1
            notifyMainContentLayoutChanged()
        } else if !nearBottom && statusBarPeekActive {
            statusBarPeekActive = false
            sidebarLayoutRevision += 1
            notifyMainContentLayoutChanged()
        }
    }

    private func observeViewModeChanges() {
        _ = NotificationCenter.default.addObserver(
            forName: .prowserViewModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else { return }
                let raw = notification.object as? String ?? ""
                let newMode = ViewMode(rawValue: raw) ?? .thumbnail
                self.handleViewModeTransition(to: newMode)
            }
        }
    }

    private func handleViewModeTransition(to newMode: ViewMode) {
        refreshMenuState()
        let previous = lastViewMode
        if previous != .browse && newMode == .browse {
            prepareBrowseReturnStateIfNeeded()
        }
        if previous == .browse && newMode == .thumbnail {
            restoreBrowseReturnStateIfNeeded()
        }
        lastViewMode = newMode
    }

    /// Drop stashed thumbnail context so exiting browse uses the current directory listing.
    func clearBrowseReturnState() {
        browseReturnThumbnailState = nil
    }

    private func prepareBrowseReturnStateIfNeeded() {
        guard browseReturnThumbnailState == nil else { return }
        guard shouldStashThumbnailContextForBrowse() else { return }
        browseReturnThumbnailState = BrowseReturnThumbnailState(
            displayedImages: fileData.displayedImages,
            currentIndex: fileData.currentIndex,
            currentImagePath: fileData.currentImagePath,
            currentDirectory: fileData.currentDirectory,
            specificFilesActive: specificFilesActive,
            sortMode: config.string(forKey: "sort_mode", default: "date"),
            sortReversed: config.bool(forKey: "sort_reversed", default: false),
            thumbnailCellSize: config.double(forKey: "thumbnail_cell_size", default: ThumbnailLayout.defaultCellSize),
            manualThumbnailSize: config.bool(forKey: "manual_thumbnail_size", default: false)
        )
    }

    private func shouldStashThumbnailContextForBrowse() -> Bool {
        if specificFilesActive { return true }
        if config.string(forKey: "sort_mode", default: "date") == SortMode.custom.rawValue {
            return true
        }
        return false
    }

    private func restoreBrowseReturnStateIfNeeded() {
        guard let stashed = browseReturnThumbnailState else { return }
        browseReturnThumbnailState = nil
        config.updateSetting("sort_mode", value: stashed.sortMode)
        config.updateSetting("sort_reversed", value: stashed.sortReversed)
        if let directory = stashed.currentDirectory {
            fileData.setCurrentDirectory(directory)
        }
        setSpecificFilesActive(stashed.specificFilesActive)
        fileData.setDisplayedImages(stashed.displayedImages)
        if let path = stashed.currentImagePath {
            fileData.setCurrentImagePath(path)
        } else {
            fileData.setCurrentIndex(stashed.currentIndex)
        }
        config.updateSetting("thumbnail_cell_size", value: stashed.thumbnailCellSize)
        config.updateSetting("manual_thumbnail_size", value: stashed.manualThumbnailSize)
        config.applySettingsChange(emit: eventBus)
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

    func openReferencePaths(_ paths: [String], focusPath: String?) {
        let normalized = paths.compactMap { FileDataModel.normalizePath($0) }
        guard normalized.count >= 2 else { return }
        clearReferenceGraphPresentation()
        config.updateSetting("sort_mode", value: SortMode.custom.rawValue)
        config.updateSetting("sort_reversed", value: false)
        let directory = URL(fileURLWithPath: normalized[0]).deletingLastPathComponent().path
        setSpecificFilesActive(true)
        fileData.setCurrentDirectory(directory)
        fileData.setDisplayedImages(normalized)
        if let focusPath, let index = normalized.firstIndex(of: focusPath) {
            fileData.setCurrentIndex(index)
            fileData.setCurrentImagePath(focusPath)
        } else {
            fileData.setCurrentIndex(0)
            fileData.setCurrentImagePath(normalized[0])
        }
        config.updateSetting("last_directory", value: directory)
        eventBus.emit(.directoryLoaded, payload: .string(directory))
        watchCurrentDirectory()
        selection.clear()
        status.show("Showing \(normalized.count) reference images")
    }

    func findReferences(to targetPath: String) {
        let candidates = fileData.displayedImages.filter { $0 != targetPath }
        guard !candidates.isEmpty else {
            status.show("No images are available to search")
            return
        }
        Task { @MainActor in
            let matches = await ReferenceGraphService.imagesReferencing(
                targetPath: targetPath,
                in: candidates
            )
            if matches.isEmpty {
                let name = (targetPath as NSString).lastPathComponent
                status.show("No other images reference \"\(name)\" in EXIF")
                return
            }
            findReferencesTargetPath = targetPath
            findReferencesMatches = matches
            showFindReferencesSheet = true
        }
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

    func loadDirectory(_ path: String, saveHistory: Bool = true) {
        setSpecificFilesActive(false)
        clearDeletedPlaceholders()
        directoryLoader.loadDirectory(path, saveHistory: saveHistory)
        menuRefresh.refreshAll()
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

    func toggleInformationSidebar() {
        clearChromeSuppression()
        let visible = !config.bool(forKey: "information_sidebar_visible", default: true)
        config.updateSetting("information_sidebar_visible", value: visible)
        if visible { revealSidebarColumn(.right) }
        noteSidebarLayoutChanged()
    }

    func toggleShortcutsSidebar() {
        clearChromeSuppression()
        let visible = !config.bool(forKey: "shortcuts_sidebar_visible", default: true)
        config.updateSetting("shortcuts_sidebar_visible", value: visible)
        if visible { revealSidebarColumn(.right) }
        noteSidebarLayoutChanged()
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

    /// Show/focus file tree on the active image directory (Python tree show + `highlight_current_file`).
    func revealFileTreeFocusedOnActiveImage() {
        fileTreeSyncActiveImageToken += 1
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

    func openBrowseFromSlideshow() {
        fileData.setViewMode(.browse)
    }

    func adjustSlideshowRate(slower: Bool) {
        let rateMS = config.int(forKey: "slideshow_rate", default: 5000)
        let newRateMS: Int
        if rateMS < 1000 {
            let rateSec = Double(rateMS) / 1000.0
            let step = slower ? 0.125 : -0.125
            newRateMS = Int(round(min(10.0, max(0.0, rateSec + step)) * 1000))
        } else {
            newRateMS = slower ? min(60_000, rateMS + 1000) : max(0, rateMS - 1000)
        }
        config.updateSetting("slideshow_rate", value: newRateMS)
        config.applySettingsChange(emit: eventBus)
        let sec = Double(newRateMS) / 1000.0
        status.show(sec >= 1.0 ? "Slideshow rate: \(sec)s" : "Slideshow rate: \(newRateMS)ms")
    }

    func adjustSlideshowTransitionSpeed(slower: Bool) {
        let current = config.int(forKey: "slideshow_transition_speed", default: 1300)
        let next = slower ? min(6000, current + 100) : max(0, current - 100)
        config.updateSetting("slideshow_transition_speed", value: next)
        config.applySettingsChange(emit: eventBus)
        status.show("Transition speed: \(next)ms")
    }

    func adjustSlideshowMaxRotation(increase: Bool) {
        let current = config.int(forKey: "slideshow_max_rotation", default: 0)
        let next = increase ? min(360, current + 5) : max(0, current - 5)
        config.updateSetting("slideshow_max_rotation", value: next)
        config.applySettingsChange(emit: eventBus)
        status.show("Max rotation: \(next)°")
    }

    func setSlideshowDirection(_ direction: String) {
        config.updateSetting("slideshow_direction", value: direction)
        config.applySettingsChange(emit: eventBus)
        let label: String
        switch direction {
        case "left": label = "From left"
        case "right": label = "From right"
        case "top": label = "From top"
        case "bottom": label = "From bottom"
        case "random": label = "Random"
        case "none": label = "None (no transition)"
        default: label = direction
        }
        status.show("Slideshow direction: \(label)")
    }

    func slideshowDirectionAdvanceIfMatches(_ direction: String) -> Bool {
        let current = config.string(forKey: "slideshow_direction", default: "right")
        if current == direction {
            slideshowStep(delta: 1)
            return true
        }
        setSlideshowDirection(direction)
        return true
    }

    func setFileTreeFilterMode(_ mode: String) {
        filterSettings.setFilteredTree(mode)
        refreshFileTreeFilter()
        config.applySettingsChange(emit: eventBus)
        eventBus.emit(.filterTreeModeChanged)
    }

    func applyFilenameFilterPattern(_ pattern: String) {
        filterSettings.setFilterPattern(pattern, persist: true)
        refreshFileTreeFilter()
        refreshDirectory()
        config.applySettingsChange(emit: eventBus)
        eventBus.emit(.filterPatternChanged)
    }

    func refreshFileTreeFilter() {
        FileTreeFilter.invalidateCache()
        fileTreeReloadToken += 1
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
            showEditUserCommentSheet = true
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
                editUserCommentError = error.localizedDescription
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
        DisplayedImagesSync.ensureActiveImageListed(fileData: fileData)
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
        guard window.isVisible, window.canBecomeKey else { return false }
        switch window.title {
        case "Settings":
            return false
        default:
            return true
        }
    }

    func confirmQuitIfRunning() -> Bool {
        true
    }

    func prepareForApplicationExit() {}

    func setFileTreeToolbarVisible(_ visible: Bool) {
        guard fileTreeToolbarVisible != visible else { return }
        fileTreeToolbarVisible = visible
        config.updateSetting("file_tree_show_toolbar", value: visible)
        config.applySettingsChange(emit: eventBus)
    }

    func setInformationMenuBarVisible(_ visible: Bool) {
        guard informationMenuBarVisible != visible else { return }
        informationMenuBarVisible = visible
        config.updateSetting("information_show_menu_bar", value: visible)
        config.applySettingsChange(emit: eventBus)
    }

    private func loadSidebarToolbarSettings() {
        fileTreeToolbarVisible = config.bool(forKey: "file_tree_show_toolbar", default: true)
        informationMenuBarVisible = config.bool(forKey: "information_show_menu_bar", default: true)
    }

    func reloadSidebarWidthsFromConfig() {
        leftSidebarWidth = SidebarWidthLimits.clampLeft(config.sidebarWidth)
        rightSidebarWidth = SidebarWidthLimits.clampRight(config.rightSidebarWidth)
    }

    func refreshSidebarLayout() {
        reloadSidebarWidthsFromConfig()
        sidebarLayoutRevision += 1
    }

    func updateLeftSidebarWidth(_ width: CGFloat) {
        let clamped = SidebarWidthLimits.clampLeft(width)
        guard clamped > 0, abs(clamped - leftSidebarWidth) > 1 else { return }
        leftSidebarWidth = clamped
        persistSidebarWidth(side: .left, width: clamped)
    }

    func updateRightSidebarWidth(_ width: CGFloat) {
        let clamped = SidebarWidthLimits.clampRight(width)
        guard clamped > 0, abs(clamped - rightSidebarWidth) > 1 else { return }
        rightSidebarWidth = clamped
        persistSidebarWidth(side: .right, width: clamped)
    }

    func persistSidebarWidth(side: SidebarSplitSide, width: CGFloat) {
        let rounded = Int(round(width))
        let minimum = side == .left
            ? Int(SidebarWidthLimits.leftMin)
            : Int(SidebarWidthLimits.rightMin)
        guard rounded >= minimum else { return }
        switch side {
        case .left:
            if Int(round(config.sidebarWidth)) != rounded {
                config.updateSetting("sidebar_width", value: rounded)
            }
        case .right:
            if Int(round(config.rightSidebarWidth)) != rounded {
                config.updateSetting("right_sidebar_width", value: rounded)
            }
        }
    }

    /// Flush sidebar column widths to `settings.json` (quit + layout changes). Pane sizes are
    /// already saved at drag end / fit (Python `saved_splitter_sizes`).
    func persistAllSidebarLayout() {
        persistSidebarWidth(side: .left, width: leftSidebarWidth)
        persistSidebarWidth(side: .right, width: rightSidebarWidth)
        if !chromeSuppressed {
            persistChromeVisibilityToConfig()
        }
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
            eventBus.emit(.filterPatternChanged)
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
        DisplayedImagesSync.ensureActiveImageListed(fileData: fileData)
        fileData.setViewMode(.thumbnail)
        status.show(hadFilter ? "Opened file, filter cleared" : "Opened file")
    }

    private func showMapAlert(title: String, message: String) {
        StyledMessageDialog.showWarning(title: title, message: message)
    }

    /// Port of Python ``preview_widget.isVisible()`` for thumbnail click behavior.
    var isPreviewPaneVisible: Bool {
        if fileData.currentViewMode == .browse { return false }
        guard config.bool(forKey: "left_sidebar_visible", default: true) else { return false }
        return config.bool(forKey: "preview_visible", default: true)
    }

    /// Exit browse mode and return to thumbnail view (port of ``close_browse_view``).
    func closeBrowseView() {
        if let path = fileData.currentImagePath,
           let index = fileData.displayedImages.firstIndex(of: path) {
            fileData.setCurrentIndex(index)
        }
        fileData.setViewMode(.thumbnail)
    }

    /// True when at least one left sidebar pane is open.
    var leftSidebarPaneActive: Bool {
        if fileData.currentViewMode == .browse { return false }
        if config.bool(forKey: "file_tree_visible", default: true) { return true }
        if config.bool(forKey: "preview_visible", default: true) { return true }
        return false
    }

    /// True when at least one right sidebar pane is open.
    var rightSidebarPaneActive: Bool {
        if config.bool(forKey: "shortcuts_sidebar_visible", default: true) { return true }
        if config.bool(forKey: "information_sidebar_visible", default: true) { return true }
        return false
    }

    var statusBarColumnVisible: Bool {
        !chromeSuppressed && config.bool(forKey: "status_bar_visible", default: true)
    }

    var effectiveStatusBarHeight: CGFloat {
        if let override = chromeLayoutOverride {
            return override.statusBarHeight
        }
        if statusBarColumnVisible { return ChromeLayoutAnimator.statusBarHeight }
        if statusBarPeekActive,
           config.bool(forKey: "raise_status_bar_on_cursor_near_bottom", default: true) {
            return ChromeLayoutAnimator.statusBarHeight
        }
        return 0
    }

    var effectiveLeftSidebarWidth: CGFloat {
        if let override = chromeLayoutOverride {
            return override.leftWidth
        }
        return leftSidebarColumnVisible ? leftSidebarWidth : 0
    }

    var effectiveRightSidebarWidth: CGFloat {
        if let override = chromeLayoutOverride {
            return override.rightWidth
        }
        return rightSidebarColumnVisible ? rightSidebarWidth : 0
    }

    var effectiveLeftSidebarVisible: Bool {
        if chromeLayoutOverride != nil {
            return (chromeLayoutOverride?.leftWidth ?? 0) > 0.5
        }
        return leftSidebarColumnVisible
    }

    var effectiveRightSidebarVisible: Bool {
        if chromeLayoutOverride != nil {
            return (chromeLayoutOverride?.rightWidth ?? 0) > 0.5
        }
        return rightSidebarColumnVisible
    }

    var leftSidebarColumnVisible: Bool {
        !chromeSuppressed
            && config.bool(forKey: "left_sidebar_visible", default: true)
            && leftSidebarPaneActive
    }

    var rightSidebarColumnVisible: Bool {
        !chromeSuppressed
            && config.bool(forKey: "right_sidebar_visible", default: true)
            && rightSidebarPaneActive
    }

    var isAnyChromeVisible: Bool {
        statusBarColumnVisible || leftSidebarColumnVisible || rightSidebarColumnVisible
    }

    var chromeToggleMenuTitle: String {
        isAnyChromeVisible ? "Hide Panes" : "Show Panes"
    }

    func toggleChrome() {
        if isAnyChromeVisible {
            chromeSavedLayout = captureChromeLayout()
            let from = currentChromeLayoutSnapshot()
            let to = ChromeLayoutSnapshot(leftWidth: 0, rightWidth: 0, statusBarHeight: 0)
            animateChromeLayout(from: from, to: to) {
                self.chromeSuppressed = true
                self.chromeLayoutOverride = nil
                self.persistChromeVisibilityToConfig()
                self.noteSidebarLayoutChanged()
            }
        } else {
            if let saved = chromeSavedLayout {
                chromeSuppressed = false
                restoreChromeLayout(saved)
            } else {
                chromeSuppressed = false
                showDefaultChrome()
            }
            let from = ChromeLayoutSnapshot(leftWidth: 0, rightWidth: 0, statusBarHeight: 0)
            let to = targetChromeLayoutSnapshot()
            animateChromeLayout(from: from, to: to) {
                self.chromeLayoutOverride = nil
                self.noteSidebarLayoutChanged()
            }
        }
    }

    private func captureChromeLayout() -> ChromeSavedLayout {
        ChromeSavedLayout(
            statusBarVisible: config.bool(forKey: "status_bar_visible", default: true),
            fileTreeVisible: config.bool(forKey: "file_tree_visible", default: true),
            previewVisible: config.bool(forKey: "preview_visible", default: true),
            chatVisible: config.bool(forKey: "chat_visible", default: false),
            shortcutsVisible: config.bool(forKey: "shortcuts_sidebar_visible", default: true),
            informationVisible: config.bool(forKey: "information_sidebar_visible", default: true),
            leftSidebarVisible: config.bool(forKey: "left_sidebar_visible", default: true),
            rightSidebarVisible: config.bool(forKey: "right_sidebar_visible", default: true),
            leftSidebarWidth: leftSidebarWidth,
            rightSidebarWidth: rightSidebarWidth,
            leftSplitterSizes: leftSidebarSplit.savedSizes,
            rightSplitterSizes: rightSidebarSplit.savedSizes
        )
    }

    private func restoreChromeLayout(_ layout: ChromeSavedLayout) {
        leftSidebarWidth = SidebarWidthLimits.clampLeft(layout.leftSidebarWidth)
        rightSidebarWidth = SidebarWidthLimits.clampRight(layout.rightSidebarWidth)
        if layout.leftSplitterSizes.count == 3 {
            config.saveSplitterSizes(leftSidebarSplit.persistenceKey, sizes: layout.leftSplitterSizes)
        }
        if layout.rightSplitterSizes.count == 3 {
            config.saveSplitterSizes(rightSidebarSplit.persistenceKey, sizes: layout.rightSplitterSizes)
        }
        config.updateSetting("status_bar_visible", value: layout.statusBarVisible)
        config.updateSetting("file_tree_visible", value: layout.fileTreeVisible)
        config.updateSetting("preview_visible", value: layout.previewVisible)
        config.updateSetting("chat_visible", value: layout.chatVisible)
        config.updateSetting("shortcuts_sidebar_visible", value: layout.shortcutsVisible)
        config.updateSetting("information_sidebar_visible", value: layout.informationVisible)
        config.updateSetting("left_sidebar_visible", value: layout.leftSidebarVisible)
        config.updateSetting("right_sidebar_visible", value: layout.rightSidebarVisible)
        persistSidebarWidth(side: .left, width: leftSidebarWidth)
        persistSidebarWidth(side: .right, width: rightSidebarWidth)
    }

    private func showDefaultChrome() {
        config.updateSetting("status_bar_visible", value: true)
        config.updateSetting("file_tree_visible", value: true)
        config.updateSetting("preview_visible", value: true)
        config.updateSetting("chat_visible", value: true)
        config.updateSetting("shortcuts_sidebar_visible", value: true)
        config.updateSetting("information_sidebar_visible", value: true)
        config.updateSetting("left_sidebar_visible", value: true)
        config.updateSetting("right_sidebar_visible", value: true)
    }

    private func persistChromeVisibilityToConfig() {
        if chromeSuppressed {
            config.updateSetting("status_bar_visible", value: false)
            config.updateSetting("file_tree_visible", value: false)
            config.updateSetting("preview_visible", value: false)
            config.updateSetting("chat_visible", value: false)
            config.updateSetting("shortcuts_sidebar_visible", value: false)
            config.updateSetting("information_sidebar_visible", value: false)
            config.updateSetting("right_sidebar_visible", value: false)
            return
        }
        let layout = captureChromeLayout()
        config.updateSetting("status_bar_visible", value: layout.statusBarVisible)
        config.updateSetting("file_tree_visible", value: layout.fileTreeVisible)
        config.updateSetting("preview_visible", value: layout.previewVisible)
        config.updateSetting("chat_visible", value: layout.chatVisible)
        config.updateSetting("shortcuts_sidebar_visible", value: layout.shortcutsVisible)
        config.updateSetting("information_sidebar_visible", value: layout.informationVisible)
        config.updateSetting("right_sidebar_visible", value: layout.rightSidebarVisible)
    }

    private func clearChromeSuppression() {
        chromeSuppressed = false
    }

    func onSidebarPaneToggled(side: SidebarSplitSide, paneIndex: Int, nowVisible: Bool) {
        if side == .left, nowVisible, paneIndex != 2,
           config.bool(forKey: "chat_visible", default: false) {
            config.updateSetting("chat_visible", value: false)
        }
        if nowVisible {
            revealSidebarColumn(side)
        }
        noteSidebarLayoutChanged()
    }

    func noteSidebarLayoutChanged() {
        if !chromeSuppressed {
            config.updateSetting("left_sidebar_visible", value: leftSidebarPaneActive)
            config.updateSetting("right_sidebar_visible", value: rightSidebarPaneActive)
        }
        // Pane sizes are persisted only by user drag / fit (Python `_on_splitter_moved`,
        // `_resize_pane_to_height`); show/hide relayouts from the saved sizes.
        sidebarLayoutRevision += 1
        notifyMainContentLayoutChanged()
    }

    func notifyMainContentLayoutChanged() {
        eventBus.emit(.mainContentLayoutChanged)
        MainWindowKeyViewLoop.sync(appState: self)
    }

    func handleTreeForwardedKeyboard(_ event: NSEvent) -> Bool {
        keyboardHandler.handleKeyEventFromTree(event)
    }

    private func setLeftSidebarPaneVisible(configKey: String, visible: Bool) {
        clearChromeSuppression()
        if visible, configKey != "chat_visible",
           config.bool(forKey: "chat_visible", default: false) {
            config.updateSetting("chat_visible", value: false)
        }
        config.updateSetting(configKey, value: visible)
        if visible { revealSidebarColumn(.left) }
        noteSidebarLayoutChanged()
    }

    private func revealSidebarColumn(_ side: SidebarSplitSide) {
        switch side {
        case .left:
            config.updateSetting("left_sidebar_visible", value: true)
        case .right:
            config.updateSetting("right_sidebar_visible", value: true)
        }
    }

    func toggleStatusBar() {
        clearChromeSuppression()
        let currentlyVisible = config.bool(forKey: "status_bar_visible", default: true)
        let from = currentChromeLayoutSnapshot()
        if currentlyVisible {
            let to = ChromeLayoutSnapshot(
                leftWidth: from.leftWidth,
                rightWidth: from.rightWidth,
                statusBarHeight: 0
            )
            animateChromeLayout(from: from, to: to) {
                self.config.updateSetting("status_bar_visible", value: false)
                self.chromeLayoutOverride = nil
                self.notifyMainContentLayoutChanged()
            }
        } else {
            config.updateSetting("status_bar_visible", value: true)
            let to = ChromeLayoutSnapshot(
                leftWidth: from.leftWidth,
                rightWidth: from.rightWidth,
                statusBarHeight: ChromeLayoutAnimator.statusBarHeight
            )
            animateChromeLayout(from: from, to: to) {
                self.chromeLayoutOverride = nil
                self.notifyMainContentLayoutChanged()
            }
        }
    }

    func applySortMode(_ mode: SortMode, reversed: Bool) {
        if fileData.currentViewMode == .list {
            fileData.setViewMode(.thumbnail)
        }
        guard fileData.currentViewMode == .thumbnail || fileData.currentViewMode == .browse else { return }
        guard !fileData.displayedImages.isEmpty else { return }

        config.updateSetting("sort_mode", value: mode.rawValue)
        config.updateSetting("sort_reversed", value: reversed)
        if mode != .exifDate && mode != .exifYear && mode != .duplicates {
            clearDeletedPlaceholders()
        }
        applyCurrentSort()
        status.show(Self.sortStatusMessage(mode: mode, reversed: reversed))
        menuRefresh.refreshAll()
    }

    /// Re-sort the current displayed list in place (Python `apply_current_sort`).
    /// Does not rescan the directory.
    func applyCurrentSort() {
        let current = fileData.currentImagePath
        let options = SortingService.Options.from(config: config)
        let sorted = SortingService.sorted(
            fileData.displayedImages,
            options: options,
            metadataCache: metadataCache
        )
        metadataCache.saveIfNeeded()
        fileData.setDisplayedImages(sorted)
        if let current, sorted.contains(current) {
            fileData.setCurrentImagePath(current)
        }
    }

    private static func sortStatusMessage(mode: SortMode, reversed: Bool) -> String {
        switch mode {
        case .size:
            let direction = reversed ? "Smallest first" : "Largest first"
            return "Sort mode set to Size (\(direction))"
        case .name:
            return reversed ? "Sort mode set to Name (Z-A)" : "Sort mode set to Name (A-Z)"
        case .date:
            let direction = reversed ? "Oldest first" : "Newest first"
            return "Sort mode set to Date (\(direction))"
        case .exifDate:
            let direction = reversed ? "Oldest first" : "Newest first"
            return "Sort mode set to EXIF Date (\(direction))"
        case .exifYear:
            let direction = reversed ? "Oldest first" : "Newest first"
            return "Sort mode set to EXIF Year (\(direction))"
        case .custom:
            return "Sort mode set to Custom"
        case .random:
            return "Random Sort"
        default:
            return "Sort mode set to \(mode.displayName)"
        }
    }

    func setUseExifDate(_ enabled: Bool) {
        config.updateSetting("use_exif_date", value: enabled)
        config.applySettingsChange(emit: eventBus)
    }

    func presentFilterEditSheet() {
        showFilterDialog = true
    }

    func saveFilterPresets(_ filters: [String]) {
        config.saveFilters(filters)
    }

    private func currentChromeLayoutSnapshot() -> ChromeLayoutSnapshot {
        if let override = chromeLayoutOverride {
            return override
        }
        return targetChromeLayoutSnapshot()
    }

    private func targetChromeLayoutSnapshot() -> ChromeLayoutSnapshot {
        ChromeLayoutSnapshot(
            leftWidth: leftSidebarColumnVisible ? leftSidebarWidth : 0,
            rightWidth: rightSidebarColumnVisible ? rightSidebarWidth : 0,
            statusBarHeight: statusBarColumnVisible ? ChromeLayoutAnimator.statusBarHeight : 0
        )
    }

    private func animateChromeLayout(
        from: ChromeLayoutSnapshot,
        to: ChromeLayoutSnapshot,
        onComplete: @escaping () -> Void
    ) {
        chromeLayoutOverride = from
        sidebarLayoutRevision += 1
        ChromeLayoutAnimator.animate(from: from, to: to) { snapshot in
            self.chromeLayoutOverride = snapshot
            self.sidebarLayoutRevision += 1
            self.notifyMainContentLayoutChanged()
        } onComplete: {
            onComplete()
        }
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

    func startSlideshow(_ mode: ViewMode) {
        guard !fileData.displayedImages.isEmpty else { return }
        if fileData.currentViewMode == mode {
            fileData.setViewMode(.thumbnail)
        } else {
            fileData.setViewMode(mode)
        }
    }

    func slideshowStep(delta: Int) {
        let images = fileData.displayedImages
        guard !images.isEmpty else { return }
        let wrap = config.bool(forKey: "wrap_around", default: true)
        let next = nextSlideshowIndex(fileData.currentIndex + delta, count: images.count, wrap: wrap)
        fileData.setCurrentIndex(next)
        fileData.setCurrentImagePath(images[next])
    }

    private func nextSlideshowIndex(_ raw: Int, count: Int, wrap: Bool) -> Int {
        guard count > 0 else { return 0 }
        if wrap { return ((raw % count) + count) % count }
        return min(max(0, raw), count - 1)
    }
}

/// One-time fixes when moving from Python profile settings to Swift UI.
@MainActor
private func migrateSwiftSidebarDefaults(config: AppConfig) {
    guard config.rawSettings()["prowser_swift_migrated_file_tree"] == nil else { return }
    // Python often saves file_tree_visible=false; Swift left sidebar expects the tree shown.
    if config.rawSettings()["file_tree_visible"] as? Bool == false {
        config.updateSetting("file_tree_visible", value: true)
    }
    config.updateSetting("prowser_swift_migrated_file_tree", value: true)
}

/// Coordinates directory scans and model updates.
@MainActor
final class DirectoryLoadCoordinator {
    private unowned let appState: AppState

    init(appState: AppState) {
        self.appState = appState
        _ = appState.eventBus.subscribe(.directoryRequested) { [weak appState] event in
            guard let appState, case .string(let path) = event.payload else { return }
            appState.loadDirectory(path, saveHistory: true)
        }
    }

    func open(paths: [String]) {
        var files: [String] = []
        var directories: [String] = []
        for path in paths {
            guard let normalized = FileDataModel.normalizePath(path) else { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                directories.append(normalized)
            } else {
                files.append(normalized)
            }
        }
        if files.count == 1 {
            // Python `load_specific_files`: a single file is browse + parent-directory thumbnails,
            // not a one-item specific-files grid.
            loadFileWithDirectoryThumbnails(files[0])
        } else if !files.isEmpty {
            let dir = URL(fileURLWithPath: files[0]).deletingLastPathComponent().path
            appState.fileData.setCurrentDirectory(dir)
            appState.setSpecificFilesActive(true)
            appState.fileData.setDisplayedImages(files)
            appState.fileData.setCurrentImagePath(files[0])
            appState.config.updateSetting("last_directory", value: dir)
            appState.eventBus.emit(.directoryLoaded, payload: .string(dir))
            appState.watchCurrentDirectory()
        } else if let directory = directories.first {
            loadDirectory(directory, saveHistory: true)
        }
    }

    /// Port of Python `load_file_with_directory_thumbnails`: open the file in browse and
    /// populate `displayedImages` from its parent directory so exiting browse shows the full dir.
    func loadFileWithDirectoryThumbnails(_ targetFile: String) {
        guard FileManager.default.fileExists(atPath: targetFile) else { return }

        appState.clearBrowseReturnState()
        appState.setSpecificFilesActive(false)
        appState.directoryHistory.saveCurrent(
            fileData: appState.fileData,
            config: appState.config,
            selection: appState.selection
        )

        if appState.config.string(forKey: "sort_mode", default: "date") == SortMode.duplicates.rawValue {
            appState.config.updateSetting("sort_mode", value: SortMode.date.rawValue)
            appState.config.updateSetting("sort_reversed", value: false)
        }

        // Switch to browse before scanning so the thumbnail grid is not shown first.
        if appState.fileData.currentViewMode != .browse {
            appState.fileData.setViewMode(.browse)
        }
        appState.clearBrowseReturnState()

        let normalizedTarget = FileDataModel.normalizePath(targetFile) ?? targetFile
        // Pin the opened file before the directory scan so browse does not flash image 0.
        appState.fileData.setCurrentImagePath(normalizedTarget)

        let directory = URL(fileURLWithPath: targetFile).deletingLastPathComponent().path
        appState.loadDirectory(directory, saveHistory: false)

        appState.fileData.setCurrentImagePath(normalizedTarget)
        appState.fileData.setViewMode(.browse)
        appState.clearBrowseReturnState()
        appState.menuRefresh.refreshAll()
    }

    func loadDirectory(_ path: String, saveHistory: Bool) {
        if saveHistory {
            appState.directoryHistory.saveCurrent(
                fileData: appState.fileData,
                config: appState.config,
                selection: appState.selection
            )
        }
        let scanned = DirectoryScanner.scanDirectory(
            at: path,
            extensions: appState.config.imageExtensions,
            filterPattern: appState.filterSettings.filterPattern
        )
        let options = SortingService.Options.from(config: appState.config)
        let images = SortingService.sorted(scanned, options: options, metadataCache: appState.metadataCache)
        appState.metadataCache.saveIfNeeded()
        appState.fileData.setCurrentDirectory(path)
        let pinnedPath = appState.fileData.currentImagePath
        appState.fileData.setDisplayedImages(images)
        if let pinnedPath, let normalized = FileDataModel.normalizePath(pinnedPath) {
            if images.contains(normalized) {
                appState.fileData.setCurrentImagePath(normalized)
            } else if FileManager.default.fileExists(atPath: normalized) {
                appState.fileData.setCurrentImagePath(normalized)
            } else if let first = images.first {
                appState.fileData.setCurrentImagePath(first)
            }
        } else if let first = images.first {
            appState.fileData.setCurrentImagePath(first)
        }
        DisplayedImagesSync.ensureActiveImageListed(fileData: appState.fileData)
        appState.config.updateSetting("last_directory", value: path)
        appState.config.recordRecentDirectory(path)
        appState.eventBus.emit(.directoryLoaded, payload: .string(path))
        appState.watchCurrentDirectory()
    }

    func goBack() {
        let current = appState.directoryHistory.entry(
            from: appState.fileData,
            config: appState.config,
            selection: appState.selection
        )
        guard let previous = appState.directoryHistory.goBack(current: current) else { return }
        restoreBrowsingState(previous)
    }

    func goForward() {
        let current = appState.directoryHistory.entry(
            from: appState.fileData,
            config: appState.config,
            selection: appState.selection
        )
        guard let next = appState.directoryHistory.goForward(current: current) else { return }
        restoreBrowsingState(next)
    }

    private func restoreBrowsingState(_ entry: DirectoryHistory.Entry) {
        appState.config.updateSetting("sort_mode", value: entry.sortMode)
        appState.config.updateSetting("sort_reversed", value: entry.sortReversed)
        if let directory = entry.directory {
            appState.fileData.setCurrentDirectory(directory)
        }
        if !entry.displayedImages.isEmpty {
            appState.fileData.setDisplayedImages(entry.displayedImages)
            if entry.referenceGraphActive {
                appState.setSpecificFilesActive(true)
            } else if let directory = entry.directory {
                let scanned = Set(DirectoryScanner.scanDirectory(
                    at: directory,
                    extensions: appState.config.imageExtensions,
                    filterPattern: appState.filterSettings.filterPattern
                ))
                appState.setSpecificFilesActive(Set(entry.displayedImages) != scanned)
            } else {
                appState.setSpecificFilesActive(true)
            }
            // Python `_restore_state_direct`: restore reference_graph presentation for that level.
            if entry.referenceGraphActive {
                let paths = entry.displayedImages
                let focus = entry.referenceGraphFocusPath ?? entry.currentPath
                Task { @MainActor in
                    await appState.setReferenceGraphPresentation(paths: paths, focusPath: focus)
                }
            } else {
                appState.clearReferenceGraphPresentation()
            }
            appState.watchCurrentDirectory()
        } else if let directory = entry.directory {
            loadDirectory(directory, saveHistory: false)
        }
        appState.directoryHistory.applyEntry(entry, to: appState.fileData)
        appState.fileData.setViewMode(entry.viewMode)
        SelectionService.restoreSelections(appState: appState, selectedFiles: entry.selectedFiles)
    }
}

private struct BrowseReturnThumbnailState {
    var displayedImages: [String]
    var currentIndex: Int
    var currentImagePath: String?
    var currentDirectory: String?
    var specificFilesActive: Bool
    var sortMode: String
    var sortReversed: Bool
    var thumbnailCellSize: Double
    var manualThumbnailSize: Bool
}

