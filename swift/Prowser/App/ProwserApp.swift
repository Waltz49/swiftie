import AppKit
import SwiftUI

@main
struct ProwserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environment(appState)
                .onAppear {
                    appDelegate.appState = appState
                }
        }
        .commands {
            ProwserCommands(appState: appState)
        }

        Window("Job Control", id: "jobs-panel") {
            FloatingJobQueuePanelView()
                .environment(appState)
                .frame(minWidth: 280, minHeight: 220)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 320, height: 420)

        Window("Image Generation", id: "imagegen-unified") {
            ImageGenUnifiedDialog()
                .environment(appState)
        }
        .defaultSize(width: 720, height: 560)

        Settings {
            SettingsWindowView()
                .environment(appState)
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
    var jobsVisible: Bool
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
    let fileOperations: FileOperationsService
    let exifOperations = ExifOperationsController()
    let searchOperations = SearchOperationsService()
    let fileTreeOperations = FileTreeOperationsService()
    let status = StatusNotificationService()
    private let keyboardHandler = KeyboardHandlerController()
    let chat: ChatController
    let theme: ThemeService
    let workers: WorkerServices
    let imageGen: ImageGenController
    let leftSidebarSplit: SidebarPaneSplitModel
    let rightSidebarSplit: SidebarPaneSplitModel
    let directoryHistory = DirectoryHistory()
    var jobsDisplayMode: JobsDisplayMode = .pane
    var jobsQueueSizeMode: JobsQueueSizeMode = .all
    var showFloatingJobsPanel = false
    var fileTreeFocusToken = 0
    var showImageGenCreateSheet = false
    var showImageGenUnifiedDialog = false
    var imageGenDialogReloadToken = 0
    var imageGenDialogRequest = ImageGenDialogRequest.empty
    var showKeyboardHelp = false
    var showAbout = false
    var showSimilaritySearchSheet = false
    var showPersonSearchSheet = false
    var showFindReferencesSheet = false
    var showFilterDialog = false
    var findReferencesTargetPath: String?
    var findReferencesMatches: [String] = []
    var exifBatchConfirmation: ExifBatchConfirmationState?
    var chromeLayoutOverride: ChromeLayoutSnapshot?
    var numberOverlayVisible = false
    var chromeSuppressed = false
    var fileTreeToolbarVisible = true
    var informationMenuBarVisible = true
    var jobsToolbarVisible = true
    var chatToolbarVisible = true
    var jobsPanelAlwaysOnTop = false
    var fileTreeCollapseToken = 0
    var fileTreeReloadToken = 0
    var personSearchPrefillDirectory: String?
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
        jobsDisplayMode = JobsDisplayMode.normalize(config.string(forKey: "jobs_display_mode", default: "pane"))
        jobsQueueSizeMode = JobsQueueSizePersistence.load(config: config)
        filterSettings.loadFromConfig()
        let profilePaths = ProfilePaths(profilePath: launchOptions.profilePath)
        thumbnailCache = ThumbnailCache(
            paths: profilePaths,
            ignoreExifRotation: config.ignoreExifRotation
        )
        metadataCache = MetadataCacheService(paths: profilePaths)
        fileOperations = FileOperationsService()
        theme = ThemeService(config: config)
        workers = WorkerServices(profilePath: launchOptions.profilePath)
        workers.reloadSettings(config: config)
        chat = ChatController(chatBridge: workers.chat, dataDirectory: config.dataDirectory)
        imageGen = ImageGenController(
            config: config,
            modelTasks: workers.modelTasks,
            foregroundTasks: workers.foregroundModelTasks,
            registry: workers.imageGenRegistry
        )
        loadSidebarToolbarSettings()
        imageGen.onImageGenerated = { [weak self] path in
            guard let self else { return }
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
            if dir == self.fileData.currentDirectory {
                self.loadDirectory(dir, saveHistory: false)
            }
        }
        directoryLoader = DirectoryLoadCoordinator(appState: self)
        fileOperations.bind(self)
        exifOperations.bind(self)
        searchOperations.bind(self)
        fileTreeOperations.bind(self)
        keyboardHandler.bind(self)
        workers.face.onFinished = { [weak self] count in
            Task { @MainActor in self?.status.show("Face extraction complete (\(count) cached)") }
        }
        workers.face.onError = { [weak self] message in
            Task { @MainActor in self?.status.show(message) }
        }
        KeyboardInputTracer.installIfNeeded(config: config)

        _ = eventBus.subscribe(.settingsChanged) { [weak self] _ in
            guard let self else { return }
            self.loadSidebarToolbarSettings()
            self.chat.reloadPersistenceSettings()
            self.theme.reload()
            self.workers.reloadSettings(config: self.config)
            KeyboardInputTracer.installIfNeeded(config: self.config)
            if let dir = self.fileData.currentDirectory {
                self.loadDirectory(dir, saveHistory: false)
            }
        }

        directoryWatcher.onRefresh = { [weak self] in
            guard let self, let dir = self.fileData.currentDirectory else { return }
            guard !self.isDirectoryRefreshSuppressed else { return }
            self.loadDirectory(dir, saveHistory: false)
        }

        startNamedPipeListener()
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

    func findReferences(to targetPath: String) {
        let candidates = fileData.displayedImages.filter { $0 != targetPath }
        guard !candidates.isEmpty else {
            status.show("No images are available to search")
            return
        }
        let matches = ReferenceGraphService.imagesReferencing(targetPath: targetPath, in: candidates)
        if matches.isEmpty {
            let name = (targetPath as NSString).lastPathComponent
            status.show("No other images reference \"\(name)\" in EXIF")
            return
        }
        findReferencesTargetPath = targetPath
        findReferencesMatches = matches
        showFindReferencesSheet = true
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
        directoryLoader.loadDirectory(path, saveHistory: saveHistory)
    }

    func goBack() {
        directoryLoader.goBack()
    }

    func goForward() {
        directoryLoader.goForward()
    }

    func refreshDirectory() {
        guard let dir = fileData.currentDirectory else { return }
        loadDirectory(dir, saveHistory: false)
    }

    func watchCurrentDirectory() {
        directoryWatcher.watch(directory: fileData.currentDirectory)
    }

    /// Python `toggle_thumbnail_filename_overlay`: None → Name → Size → Both → None.
    /// In browse mode, ⌘I toggles the information sidebar instead.
    func cycleThumbnailOverlay() {
        if fileData.currentViewMode == .browse {
            toggleInformationSidebar()
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
    }

    func toggleInformationSidebar() {
        clearChromeSuppression()
        let visible = !config.bool(forKey: "information_sidebar_visible", default: true)
        config.updateSetting("information_sidebar_visible", value: visible)
        if visible { revealSidebarColumn(.right) }
        noteSidebarLayoutChanged()
        config.applySettingsChange(emit: eventBus)
    }

    func toggleShortcutsSidebar() {
        clearChromeSuppression()
        let visible = !config.bool(forKey: "shortcuts_sidebar_visible", default: true)
        config.updateSetting("shortcuts_sidebar_visible", value: visible)
        if visible { revealSidebarColumn(.right) }
        noteSidebarLayoutChanged()
        config.applySettingsChange(emit: eventBus)
    }

    func toggleFileTree() {
        clearChromeSuppression()
        let visible = !config.bool(forKey: "file_tree_visible", default: true)
        config.updateSetting("file_tree_visible", value: visible)
        if visible { revealSidebarColumn(.left) }
        noteSidebarLayoutChanged()
        config.applySettingsChange(emit: eventBus)
    }

    func toggleJobsPane() {
        guard BundleCapabilities.imageGenUIEnabled else { return }
        if jobsDisplayMode == .pane,
           config.bool(forKey: "jobs_visible", default: true) {
            config.updateSetting("jobs_visible", value: false)
            noteSidebarLayoutChanged()
            config.applySettingsChange(emit: eventBus)
            return
        }
        showJobsPane()
    }

    func showJobsPane() {
        guard BundleCapabilities.imageGenUIEnabled else { return }
        showFloatingJobsPanel = false
        jobsDisplayMode = .pane
        config.updateSetting("jobs_display_mode", value: JobsDisplayMode.pane.rawValue)
        config.updateSetting("jobs_visible", value: true)
        revealSidebarColumn(.right)
        noteSidebarLayoutChanged()
        config.applySettingsChange(emit: eventBus)
        syncJobsPaneGeometry()
    }

    func showJobsPanel() {
        guard BundleCapabilities.imageGenUIEnabled else { return }
        config.updateSetting("jobs_visible", value: false)
        jobsDisplayMode = .panel
        config.updateSetting("jobs_display_mode", value: JobsDisplayMode.panel.rawValue)
        showFloatingJobsPanel = true
        noteSidebarLayoutChanged()
        config.applySettingsChange(emit: eventBus)
    }

    func hideJobsPanel() {
        showFloatingJobsPanel = false
    }

    func toggleJobsPanel() {
        guard BundleCapabilities.imageGenUIEnabled else { return }
        if showFloatingJobsPanel {
            hideJobsPanel()
            return
        }
        showJobsPanel()
    }

    func cycleActiveJobsSurfaceSize() {
        guard BundleCapabilities.imageGenUIEnabled else { return }
        if showFloatingJobsPanel {
            cycleJobsQueueSizeMode()
            return
        }
        if jobsDisplayMode == .pane {
            rightSidebarSplit.cycleJobsPaneSize(appState: self)
        }
    }

    func setJobsQueueSizeMode(_ mode: JobsQueueSizeMode, requireActive: Bool = false) {
        guard BundleCapabilities.imageGenUIEnabled else { return }
        if requireActive, !imageGen.isProcessing, imageGen.queue.jobs.isEmpty { return }
        applyJobsQueueSizeMode(mode, forceRefit: true)
    }

    func applyJobsQueueSizeMode(_ mode: JobsQueueSizeMode, forceRefit: Bool) {
        if jobsQueueSizeMode == mode, !forceRefit { return }
        jobsQueueSizeMode = mode
        JobsQueueSizePersistence.save(mode, config: config)
        config.updateSetting("jobs_pane_compact", value: mode == .strip)
        syncJobsPaneGeometry()
    }

    func cycleJobsQueueSizeMode() {
        applyJobsQueueSizeMode(jobsQueueSizeMode.next(), forceRefit: true)
    }

    func syncJobsPaneGeometry() {
        guard jobsDisplayMode == .pane else { return }
        rightSidebarSplit.resizeJobsPaneToMode(appState: self)
    }

    func requestFileTreeFocus() {
        fileTreeFocusToken += 1
    }

    func collapseFileTreeToHome() {
        fileTreeCollapseToken += 1
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        loadDirectory(home, saveHistory: true)
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

    func openSettingsWindow(tab: SettingsTab = .general) {
        NotificationCenter.default.post(
            name: .prowserOpenSettingsTab,
            object: nil,
            userInfo: ["tab": tab.rawValue]
        )
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    func openImageGenDialog(
        function: String? = nil,
        replaceJobID: String? = nil,
        initialPrompt: String? = nil,
        autoImportEXIF: Bool = false,
        editSourcePaths: [String] = []
    ) {
        guard imageGen.isEnabled else { return }
        let session = ImageGenSessionState()
        let resolvedFunction = function ?? session.lastFunction(config: config)
        var prompt = initialPrompt
        if autoImportEXIF, prompt == nil {
            prompt = userCommentForActiveImage()
        }
        imageGenDialogRequest = ImageGenDialogRequest(
            function: resolvedFunction,
            replaceJobID: replaceJobID,
            initialPrompt: prompt,
            autoImportEXIF: autoImportEXIF,
            editSourcePaths: editSourcePaths
        )
        if showImageGenUnifiedDialog {
            imageGenDialogReloadToken += 1
            NotificationCenter.default.post(name: .prowserRaiseImageGenDialog, object: nil)
        } else {
            showImageGenUnifiedDialog = true
        }
    }

    func closeImageGenUnifiedDialog() {
        showImageGenUnifiedDialog = false
    }

    func openFastImageGenDialog() {
        let imagegen = config.rawSettings()["imagegen"] as? [String: Any] ?? [:]
        let action = imagegen["fast_open_action"] as? String ?? "from_text"
        let comment = userCommentForActiveImage()
        if action == "edit_image" {
            openImageGenDialog(function: "edit", initialPrompt: comment, autoImportEXIF: true)
        } else {
            openImageGenDialog(function: "create", initialPrompt: comment, autoImportEXIF: true)
        }
    }

    func editActiveQueueJob() {
        let rows = imageGen.queueSnapshot()
        guard let active = rows.first(where: { $0.isActive }) ?? rows.first else { return }
        openImageGenDialog(function: nil, replaceJobID: active.jobID)
    }

    func openGeneratedImageInBrowse(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        if directory != fileData.currentDirectory {
            loadDirectory(directory, saveHistory: true)
        }
        fileData.setCurrentImagePath(path)
        fileData.setViewMode(.browse)
    }

    func userCommentForActiveImage() -> String? {
        guard let path = fileData.currentImagePath else { return nil }
        let comment = ExifService.userComment(path: path) ?? ""
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func confirmCancelGeneration() {
        guard imageGen.isProcessing else { return }
        let alert = NSAlert()
        alert.messageText = "Cancel job?"
        alert.informativeText = "Cancel the running job?"
        alert.addButton(withTitle: "Cancel Job")
        alert.addButton(withTitle: "Keep Running")
        if alert.runModal() == .alertFirstButtonReturn {
            imageGen.cancelActiveJob()
        }
    }

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

    func setJobsToolbarVisible(_ visible: Bool) {
        guard jobsToolbarVisible != visible else { return }
        jobsToolbarVisible = visible
        config.updateSetting("jobs_show_toolbar", value: visible)
        config.applySettingsChange(emit: eventBus)
    }

    func setChatToolbarVisible(_ visible: Bool) {
        guard chatToolbarVisible != visible else { return }
        chatToolbarVisible = visible
        config.updateSetting("chat_show_toolbar", value: visible)
        config.applySettingsChange(emit: eventBus)
    }

    func setJobsPanelAlwaysOnTop(_ enabled: Bool) {
        guard jobsPanelAlwaysOnTop != enabled else { return }
        jobsPanelAlwaysOnTop = enabled
        var imagegen = config.rawSettings()["imagegen"] as? [String: Any] ?? [:]
        imagegen["job_queue_always_on_top"] = enabled
        config.updateSetting("imagegen", value: imagegen)
        config.applySettingsChange(emit: eventBus)
    }

    private func loadSidebarToolbarSettings() {
        fileTreeToolbarVisible = config.bool(forKey: "file_tree_show_toolbar", default: true)
        informationMenuBarVisible = config.bool(forKey: "information_show_menu_bar", default: true)
        jobsToolbarVisible = config.bool(forKey: "jobs_show_toolbar", default: true)
        chatToolbarVisible = config.bool(forKey: "chat_show_toolbar", default: true)
        let imagegen = config.rawSettings()["imagegen"] as? [String: Any] ?? [:]
        jobsPanelAlwaysOnTop = imagegen["job_queue_always_on_top"] as? Bool ?? false
        imageGen.reloadToolbarSettings(from: imagegen)
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

    func persistSplitterSizes() {
        leftSidebarSplit.mergePersistedSizes(appState: self)
        rightSidebarSplit.mergePersistedSizes(appState: self)
    }

    /// Flush sidebar column widths and inner pane sizes to `settings.json` (quit + layout changes).
    func persistAllSidebarLayout() {
        persistSplitterSizes()
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

    func toggleChatPane() {
        clearChromeSuppression()
        let visible = !config.bool(forKey: "chat_visible", default: false)
        config.updateSetting("chat_visible", value: visible)
        if visible { revealSidebarColumn(.left) }
        noteSidebarLayoutChanged()
        config.applySettingsChange(emit: eventBus)
    }

    func togglePreviewPane() {
        clearChromeSuppression()
        let visible = !config.bool(forKey: "preview_visible", default: true)
        config.updateSetting("preview_visible", value: visible)
        if visible { revealSidebarColumn(.left) }
        noteSidebarLayoutChanged()
        config.applySettingsChange(emit: eventBus)
    }

    /// True when at least one left sidebar pane is open (browse: chat only).
    var leftSidebarPaneActive: Bool {
        if fileData.currentViewMode == .browse {
            return BundleCapabilities.chatUIEnabled
                && config.bool(forKey: "chat_visible", default: false)
        }
        if config.bool(forKey: "file_tree_visible", default: true) { return true }
        if config.bool(forKey: "preview_visible", default: true) { return true }
        if BundleCapabilities.chatUIEnabled,
           config.bool(forKey: "chat_visible", default: false) {
            return true
        }
        return false
    }

    /// True when at least one right sidebar pane is open.
    var rightSidebarPaneActive: Bool {
        if config.bool(forKey: "shortcuts_sidebar_visible", default: true) { return true }
        if config.bool(forKey: "information_sidebar_visible", default: true) { return true }
        if BundleCapabilities.imageGenUIEnabled,
           jobsDisplayMode == .pane,
           config.bool(forKey: "jobs_visible", default: true) {
            return true
        }
        return false
    }

    var statusBarColumnVisible: Bool {
        !chromeSuppressed && config.bool(forKey: "status_bar_visible", default: true)
    }

    var effectiveStatusBarHeight: CGFloat {
        if let override = chromeLayoutOverride {
            return override.statusBarHeight
        }
        return statusBarColumnVisible ? ChromeLayoutAnimator.statusBarHeight : 0
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
            persistSplitterSizes()
            chromeSavedLayout = captureChromeLayout()
            let from = currentChromeLayoutSnapshot()
            let to = ChromeLayoutSnapshot(leftWidth: 0, rightWidth: 0, statusBarHeight: 0)
            animateChromeLayout(from: from, to: to) {
                self.chromeSuppressed = true
                self.chromeLayoutOverride = nil
                self.persistChromeVisibilityToConfig()
                self.noteSidebarLayoutChanged()
                self.config.applySettingsChange(emit: self.eventBus)
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
                self.config.applySettingsChange(emit: self.eventBus)
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
            jobsVisible: config.bool(forKey: "jobs_visible", default: true),
            leftSidebarVisible: config.bool(forKey: "left_sidebar_visible", default: true),
            rightSidebarVisible: config.bool(forKey: "right_sidebar_visible", default: true),
            leftSidebarWidth: leftSidebarWidth,
            rightSidebarWidth: rightSidebarWidth,
            leftSplitterSizes: leftSidebarSplit.sizes,
            rightSplitterSizes: rightSidebarSplit.sizes
        )
    }

    private func restoreChromeLayout(_ layout: ChromeSavedLayout) {
        leftSidebarWidth = SidebarWidthLimits.clampLeft(layout.leftSidebarWidth)
        rightSidebarWidth = SidebarWidthLimits.clampRight(layout.rightSidebarWidth)
        if layout.leftSplitterSizes.count == 3 {
            leftSidebarSplit.applySizes(layout.leftSplitterSizes, appState: self, persist: false)
        }
        if layout.rightSplitterSizes.count == 3 {
            rightSidebarSplit.applySizes(layout.rightSplitterSizes, appState: self, persist: false)
        }
        config.updateSetting("status_bar_visible", value: layout.statusBarVisible)
        config.updateSetting("file_tree_visible", value: layout.fileTreeVisible)
        config.updateSetting("preview_visible", value: layout.previewVisible)
        config.updateSetting("chat_visible", value: layout.chatVisible)
        config.updateSetting("shortcuts_sidebar_visible", value: layout.shortcutsVisible)
        config.updateSetting("information_sidebar_visible", value: layout.informationVisible)
        config.updateSetting("jobs_visible", value: layout.jobsVisible)
        config.updateSetting("left_sidebar_visible", value: layout.leftSidebarVisible)
        config.updateSetting("right_sidebar_visible", value: layout.rightSidebarVisible)
        persistSidebarWidth(side: .left, width: leftSidebarWidth)
        persistSidebarWidth(side: .right, width: rightSidebarWidth)
        persistSplitterSizes()
    }

    private func showDefaultChrome() {
        config.updateSetting("status_bar_visible", value: true)
        config.updateSetting("file_tree_visible", value: true)
        config.updateSetting("preview_visible", value: true)
        config.updateSetting("chat_visible", value: true)
        config.updateSetting("shortcuts_sidebar_visible", value: true)
        config.updateSetting("information_sidebar_visible", value: true)
        config.updateSetting("jobs_visible", value: true)
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
            config.updateSetting("jobs_visible", value: false)
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
        config.updateSetting("jobs_visible", value: layout.jobsVisible)
        config.updateSetting("right_sidebar_visible", value: layout.rightSidebarVisible)
    }

    private func clearChromeSuppression() {
        chromeSuppressed = false
    }

    func onSidebarPaneToggled(side: SidebarSplitSide, nowVisible: Bool) {
        if nowVisible {
            revealSidebarColumn(side)
        }
        noteSidebarLayoutChanged()
    }

    func noteSidebarLayoutChanged() {
        sidebarLayoutRevision += 1
        if !chromeSuppressed {
            config.updateSetting("left_sidebar_visible", value: leftSidebarPaneActive)
            config.updateSetting("right_sidebar_visible", value: rightSidebarPaneActive)
            persistSplitterSizes()
        }
        notifyMainContentLayoutChanged()
    }

    func notifyMainContentLayoutChanged() {
        eventBus.emit(.mainContentLayoutChanged)
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
                self.config.applySettingsChange(emit: self.eventBus)
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
                self.config.applySettingsChange(emit: self.eventBus)
            }
        }
    }

    func applySortMode(_ mode: SortMode, reversed: Bool) {
        config.updateSetting("sort_mode", value: mode.rawValue)
        config.updateSetting("sort_reversed", value: reversed)
        refreshDirectory()
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
            let alert = NSAlert()
            alert.messageText = "Create screen size copy?"
            alert.informativeText = "Create screen-sized copies for \(paths.count) files?"
            alert.addButton(withTitle: "Create")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
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
            let alert = NSAlert()
            alert.messageText = "Screen size copy failed"
            alert.informativeText = lastError ?? "No files were processed."
            alert.runModal()
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
        guard let first = paths.first else { return }
        let expanded = (first as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
            loadDirectory(expanded, saveHistory: true)
        } else {
            let normalized = paths.compactMap { FileDataModel.normalizePath($0) }
            guard !normalized.isEmpty else { return }
            let dir = URL(fileURLWithPath: normalized[0]).deletingLastPathComponent().path
            appState.fileData.setCurrentDirectory(dir)
            appState.fileData.setDisplayedImages(normalized)
            appState.fileData.setCurrentImagePath(normalized[0])
            appState.config.updateSetting("last_directory", value: dir)
            appState.eventBus.emit(.directoryLoaded, payload: .string(dir))
            appState.watchCurrentDirectory()
            appState.workers.onDirectoryLoaded(dir)
        }
    }

    func loadDirectory(_ path: String, saveHistory: Bool) {
        if saveHistory {
            appState.directoryHistory.saveCurrent(fileData: appState.fileData)
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
        appState.fileData.setDisplayedImages(images)
        if let current = appState.fileData.currentImagePath, images.contains(current) {
            appState.fileData.setCurrentImagePath(current)
        } else if let first = images.first {
            appState.fileData.setCurrentImagePath(first)
        }
        appState.config.updateSetting("last_directory", value: path)
        appState.config.recordRecentDirectory(path)
        appState.eventBus.emit(.directoryLoaded, payload: .string(path))
        appState.watchCurrentDirectory()
        appState.workers.onDirectoryLoaded(path)
    }

    func goBack() {
        guard let current = appState.directoryHistory.entry(from: appState.fileData),
              let previous = appState.directoryHistory.goBack(current: current) else { return }
        loadDirectory(previous.directory, saveHistory: false)
        appState.directoryHistory.applyEntry(previous, to: appState.fileData)
    }

    func goForward() {
        guard let current = appState.directoryHistory.entry(from: appState.fileData),
              let next = appState.directoryHistory.goForward(current: current) else { return }
        loadDirectory(next.directory, saveHistory: false)
        appState.directoryHistory.applyEntry(next, to: appState.fileData)
    }
}

