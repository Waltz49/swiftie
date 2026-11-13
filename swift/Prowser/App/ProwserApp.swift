import AppKit
import SwiftUI
import UniformTypeIdentifiers

// defaults write $(osascript -e 'id of app "/Applications/swift-prowser.app"') NSAppSleepDisabled -bool YES

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
                ProwserFilterCommands(appState: appState)
                ProwserImageCommands(appState: appState)
                ProwserHelpCommands(appState: appState)
            }
        }

        Window("Job Control", id: "jobs-panel") {
            OptionalAppStateWindow(appState: appDelegate.appState) { appState in
                FloatingJobQueuePanelView()
                    .environment(appState)
                    .frame(
                        minWidth: 280,
                        minHeight: appState.jobsPaneMiniChromeActive ? 0 : 220
                    )
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 320, height: 420)

        Window("Image Generation", id: "imagegen-unified") {
            OptionalAppStateWindow(appState: appDelegate.appState) { appState in
                DialogCopyFeedbackRoot {
                    ImageGenUnifiedDialog()
                }
                .environment(appState)
            }
        }
        .defaultSize(width: 720, height: 560)
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

/// Coordinates directory scans and model updates.
@MainActor
final class DirectoryLoadCoordinator {
    private unowned let appState: AppState
    private var activeLoadGeneration = 0
    private var activeLoadTask: Task<Void, Never>?
    private var pendingLoadingCanvasTask: Task<Void, Never>?

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
            appState.persistRestoreState()
        } else if let directory = directories.first {
            loadDirectory(directory, saveHistory: true)
        }
    }

    /// Drop any in-flight directory scan so a specific-files level is not overwritten when it finishes.
    func cancelPendingDirectoryLoad() {
        activeLoadTask?.cancel()
        activeLoadGeneration += 1
        cancelPendingLoadingCanvas()
        appState.pendingBrowseExitThumbnailScroll = false
        if appState.isLoadingDirectory {
            appState.isLoadingDirectory = false
            if appState.showThumbnailDirectoryLoadingCanvas {
                appState.endThumbnailDirectoryLoad()
            }
            appState.showThumbnailDirectoryLoadingCanvas = false
        }
    }

    private func cancelPendingLoadingCanvas() {
        pendingLoadingCanvasTask?.cancel()
        pendingLoadingCanvasTask = nil
    }

    private func scheduleLoadingCanvasIfNeeded(
        generation: Int,
        scannedCount: Int,
        showLoadingState: Bool
    ) {
        cancelPendingLoadingCanvas()
        guard showLoadingState,
              scannedCount >= ThumbnailLayout.directoryLoadingCanvasMinimumImageCount else { return }
        pendingLoadingCanvasTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: ThumbnailLayout.directoryLoadingCanvasShowDelay)
            guard !Task.isCancelled, let self else { return }
            guard generation == self.activeLoadGeneration else { return }
            guard self.appState.isLoadingDirectory else { return }
            self.appState.showThumbnailDirectoryLoadingCanvas = true
            self.appState.beginThumbnailDirectoryLoad()
        }
    }

    /// Port of Python `load_file_with_directory_thumbnails`: open the file in browse and
    /// populate `displayedImages` from its parent directory so exiting browse shows the full dir.
    func loadFileWithDirectoryThumbnails(_ targetFile: String) {
        guard FileManager.default.fileExists(atPath: targetFile) else { return }

        cancelPendingDirectoryLoad()
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
        appState.fileData.setDisplayedImages([normalizedTarget])
        appState.fileData.setCurrentIndex(0)

        let directory = URL(fileURLWithPath: targetFile).deletingLastPathComponent().path
        loadDirectory(directory, saveHistory: false, pinnedImagePath: normalizedTarget)

        appState.fileData.setViewMode(.browse)
        appState.clearBrowseReturnState()
        appState.scheduleDeferredMenuRefresh()
    }

    /// Python ``open_reference_thumbnail_paths`` (job card reference thumbnails).
    func openReferenceThumbnailPaths(_ paths: [String]) {
        let valid = JobCardThumbnailPaths.validPreviewPaths(paths)
        guard !valid.isEmpty else { return }
        if valid.count == 1 {
            loadFileWithDirectoryThumbnails(valid[0])
            return
        }
        applySpecificFilesLevel(
            paths: valid,
            focusPath: nil,
            saveHistory: true,
            statusMessage: "Showing \(valid.count) reference images"
        )
    }

    /// Custom-order thumbnail grid for an explicit path list (reference paths, etc.).
    func applySpecificFilesLevel(
        paths: [String],
        focusPath: String?,
        saveHistory: Bool,
        statusMessage: String
    ) {
        let normalized = paths.compactMap { FileDataModel.normalizePath($0) }
        guard normalized.count >= 2 else { return }

        if saveHistory {
            appState.directoryHistory.saveCurrent(
                fileData: appState.fileData,
                config: appState.config,
                selection: appState.selection
            )
        }

        cancelPendingDirectoryLoad()
        appState.clearReferenceGraphPresentation()
        DuplicateGroupPresentation.clearDuplicatePresentation(appState: appState)
        appState.config.updateSetting("sort_mode", value: SortMode.custom.rawValue)
        appState.config.updateSetting("sort_reversed", value: false)

        let directory = URL(fileURLWithPath: normalized[0]).deletingLastPathComponent().path
        appState.setSpecificFilesActive(true)
        appState.fileData.setCurrentDirectory(directory)
        appState.fileData.setDisplayedImages(normalized)

        if let focusPath,
           let focusNorm = FileDataModel.normalizePath(focusPath),
           let index = FileDataModel.indexOfPath(focusNorm, in: normalized) {
            appState.fileData.setCurrentIndex(index)
            appState.fileData.setCurrentImagePath(normalized[index])
        } else {
            appState.fileData.setCurrentIndex(0)
            appState.fileData.setCurrentImagePath(normalized[0])
        }

        if appState.fileData.currentViewMode == .browse {
            appState.closeBrowseView()
        } else if appState.fileData.currentViewMode == .list {
            appState.toggleListView()
        } else if appState.fileData.currentViewMode == .slideshow
            || appState.fileData.currentViewMode == .slideshow2
            || appState.fileData.currentViewMode == .slideshow3 {
            appState.fileData.setViewMode(.thumbnail)
        }
        if appState.fileData.currentViewMode != .thumbnail {
            appState.fileData.setViewMode(.thumbnail)
        }

        appState.config.updateSetting("last_directory", value: directory)
        appState.eventBus.emit(.directoryLoaded, payload: .string(directory))
        appState.watchCurrentDirectory()
        appState.selection.clear()
        appState.thumbnailGridHost?.reloadLayoutIfNeeded()
        if appState.fileData.currentViewMode == .thumbnail,
           let grid = appState.thumbnailGridHost,
           let path = appState.fileData.currentImagePath,
           let pathNorm = FileDataModel.normalizePath(path),
           let index = FileDataModel.indexOfPath(pathNorm, in: normalized) {
            grid.selectIndex(index, scroll: true, notifyDelegate: false)
            grid.scrollToSelectionAfterLayout()
        }
        appState.menuRefresh.refreshAll()
        appState.status.show(statusMessage)
        appState.persistRestoreState()
    }

    func loadDirectory(
        _ path: String,
        saveHistory: Bool,
        pinnedImagePath: String? = nil,
        showLoadingState: Bool = true,
        scanFilterPattern: String? = nil,
        onComplete: (() -> Void)? = nil
    ) {
        guard let normalized = FileDataModel.normalizePath(path) else {
            onComplete?()
            return
        }

        if saveHistory {
            appState.directoryHistory.saveCurrent(
                fileData: appState.fileData,
                config: appState.config,
                selection: appState.selection
            )
        }
        if !appState.referenceGraphActive {
            appState.duplicateSections = []
            appState.setSpecificFilesActive(false)
            if appState.config.string(forKey: "sort_mode", default: "date") == SortMode.duplicates.rawValue {
                appState.config.updateSetting("sort_mode", value: SortMode.date.rawValue)
                appState.config.updateSetting("sort_reversed", value: false)
            }
        }

        activeLoadTask?.cancel()
        activeLoadGeneration += 1
        let generation = activeLoadGeneration
        cancelPendingLoadingCanvas()
        appState.pendingBrowseExitThumbnailScroll = false

        let contextChanges = appState.thumbnailContextWouldChange(forNewDirectory: normalized)

        let pin: String?
        if let explicit = pinnedImagePath.flatMap({ FileDataModel.normalizePath($0) }) {
            pin = explicit
        } else if appState.fileData.currentViewMode == .browse, !contextChanges {
            pin = appState.fileData.currentImagePath
        } else {
            pin = nil
        }

        let snapshot = DirectoryLoadBackgroundWork.Snapshot(
            path: normalized,
            extensions: appState.config.imageExtensions,
            filterPattern: scanFilterPattern ?? appState.filterSettings.filterPattern,
            sortModeRaw: appState.config.string(forKey: "sort_mode", default: "date"),
            sortReversed: appState.config.bool(forKey: "sort_reversed", default: false),
            useExifDate: appState.config.useExifDate
        )

        let firstSessionThumbnailDirectoryLoad = showLoadingState
            && !appState.hasCompletedInitialThumbnailDirectoryLoad
            && appState.fileData.currentViewMode == .thumbnail
            && pin == nil

        let eligibilityForLoadingCanvas = firstSessionThumbnailDirectoryLoad
            || (showLoadingState && contextChanges)

        if showLoadingState {
            appState.isLoadingDirectory = true
        }
        if firstSessionThumbnailDirectoryLoad {
            appState.showThumbnailDirectoryLoadingCanvas = true
        } else {
            appState.showThumbnailDirectoryLoadingCanvas = false
        }

        if eligibilityForLoadingCanvas, showLoadingState {
            appState.fileData.setDisplayedImages([])
            appState.fileData.setCurrentDirectory(normalized)
        } else if pin != nil {
            appState.fileData.setCurrentDirectory(normalized)
            if let pin {
                appState.fileData.setCurrentImagePath(pin)
            }
        } else {
            appState.fileData.setCurrentDirectory(normalized)
        }

        exitBrowseForExternalDirectoryLoadIfNeeded(explicitPinnedPath: pinnedImagePath)

        if firstSessionThumbnailDirectoryLoad {
            appState.beginThumbnailDirectoryLoad()
        }

        activeLoadTask = Task { @MainActor [weak self] in
            let scanned = await Task.detached(priority: .userInitiated) {
                DirectoryScanner.scanDirectory(
                    at: snapshot.path,
                    extensions: snapshot.extensions,
                    filterPattern: snapshot.filterPattern
                )
            }.value

            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard generation == self.activeLoadGeneration else { return }

            if eligibilityForLoadingCanvas, !firstSessionThumbnailDirectoryLoad {
                self.scheduleLoadingCanvasIfNeeded(
                    generation: generation,
                    scannedCount: scanned.count,
                    showLoadingState: showLoadingState
                )
            }

            let sortOutput = await Task.detached(priority: .userInitiated) {
                DirectoryLoadBackgroundWork.sort(scanned, snapshot: snapshot)
            }.value

            guard !Task.isCancelled else { return }
            guard generation == self.activeLoadGeneration else { return }
            self.finishDirectoryLoad(
                generation: generation,
                path: normalized,
                images: sortOutput.paths,
                duplicateHashGroups: sortOutput.duplicateHashGroups,
                pinnedPath: pin,
                showLoadingState: showLoadingState,
                onComplete: onComplete
            )
        }
    }

    /// Python external `load_directory`: leave browse except parent-dir scan with explicit pin (`load_file_with_directory_thumbnails`).
    private func exitBrowseForExternalDirectoryLoadIfNeeded(explicitPinnedPath: String?) {
        guard appState.fileData.currentViewMode == .browse else { return }
        if explicitPinnedPath != nil { return }
        appState.clearBrowseReturnState()
        if appState.returnToListViewAfterBrowse {
            appState.returnToListViewAfterBrowse = false
            appState.fileData.setViewMode(.list)
        } else {
            appState.fileData.setViewMode(.thumbnail)
        }
    }

    /// Prefer explicit pin, then existing active path, then first listing entry (path is source of truth).
    private static func resolveActiveImageAfterDirectoryLoad(
        images: [String],
        pinnedPath: String?,
        currentPath: String?,
        directory: String
    ) -> String? {
        if let pinned = pinnedPath.flatMap({ FileDataModel.normalizePath($0) }),
           FileManager.default.fileExists(atPath: pinned),
           FileDataModel.pathIsInDirectory(file: pinned, directory: directory) {
            return pinned
        }
        if images.isEmpty { return nil }
        for candidate in [pinnedPath, currentPath] {
            guard let candidate,
                  let normalized = FileDataModel.normalizePath(candidate) else { continue }
            if let match = images.first(where: { FileDataModel.pathsReferToSameFile($0, normalized) }) {
                return FileDataModel.normalizePath(match) ?? match
            }
        }
        return images.first
    }

    /// Apply a directory listing produced off the main thread (refresh / rescan).
    func applyDirectoryListing(
        path: String,
        images: [String],
        pinnedPath: String?,
        showLoadingState: Bool = false,
        onComplete: (() -> Void)? = nil
    ) {
        activeLoadTask?.cancel()
        activeLoadGeneration += 1
        let generation = activeLoadGeneration
        finishDirectoryLoad(
            generation: generation,
            path: path,
            images: images,
            duplicateHashGroups: nil,
            pinnedPath: pinnedPath,
            showLoadingState: showLoadingState,
            onComplete: onComplete
        )
    }

    private func finishDirectoryLoad(
        generation: Int,
        path: String,
        images: [String],
        duplicateHashGroups: DuplicateHashService.HashGroups?,
        pinnedPath: String?,
        showLoadingState: Bool,
        onComplete: (() -> Void)?
    ) {
        guard generation == activeLoadGeneration else { return }

        cancelPendingLoadingCanvas()

        appState.fileData.setCurrentDirectory(path)
        let order = DisplayOrderService.applyDisplayOrderWithContext(
            images,
            appState: appState,
            trustPreSortedFromDirectoryLoad: true,
            precomputedDuplicateHashGroups: duplicateHashGroups
        )
        let ordered = order.paths
        appState.fileData.setDisplayedImages(ordered)
        let sortMode = SortMode(rawValue: appState.config.string(forKey: "sort_mode", default: "date")) ?? .date
        if sortMode == .duplicates {
            appState.duplicateSections = DuplicateHashService.duplicateSections(
                forDisplayedPaths: ordered,
                sortHashGroups: order.duplicateHashGroups
            )
            appState.exifDateSections = []
        }
        let resolvedActive = Self.resolveActiveImageAfterDirectoryLoad(
            images: appState.fileData.getDisplayedImages(),
            pinnedPath: pinnedPath,
            currentPath: appState.fileData.currentImagePath,
            directory: path
        )
        appState.fileData.setCurrentImagePath(resolvedActive)
        DisplayedImagesSync.ensureActiveImageListed(
            fileData: appState.fileData,
            filterPattern: appState.filterSettings.filterPattern,
            isLoadingDirectory: false
        )

        if showLoadingState {
            appState.isLoadingDirectory = false
            if appState.showThumbnailDirectoryLoadingCanvas {
                appState.endThumbnailDirectoryLoad()
            }
        }
        appState.noteInitialThumbnailDirectoryLoadCompleted()

        appState.eventBus.emit(.directoryLoaded, payload: .string(path))

        let deferredPath = path
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, generation == self.activeLoadGeneration else { return }
            self.appState.config.updateSetting("last_directory", value: deferredPath)
            self.appState.config.recordRecentDirectory(deferredPath)
            self.appState.watchCurrentDirectory()
            self.appState.persistRestoreState()
            self.appState.scheduleDeferredMenuRefresh()
            onComplete?()
        }
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
        appState.duplicateSections = entry.duplicateSections

        let finishRestore = { [weak self] in
            guard let self else { return }
            self.appState.directoryHistory.applyEntry(entry, to: self.appState.fileData)
            self.appState.fileData.setViewMode(entry.viewMode)
            SelectionService.restoreSelections(appState: self.appState, selectedFiles: entry.selectedFiles)
            if entry.viewMode == .thumbnail {
                self.appState.scheduleScrollThumbnailGridToActiveImageAfterLayout()
            }
        }

        if !entry.displayedImages.isEmpty {
            appState.fileData.setDisplayedImages(entry.displayedImages)
            if entry.referenceGraphActive {
                appState.setSpecificFilesActive(true)
            } else if entry.specificFilesActive {
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
                    appState.scheduleScrollThumbnailGridToActiveImageAfterLayout()
                }
            } else {
                appState.clearReferenceGraphPresentation()
            }
            appState.watchCurrentDirectory()
            finishRestore()
        } else if let directory = entry.directory {
            loadDirectory(directory, saveHistory: false, onComplete: finishRestore)
        } else {
            finishRestore()
        }
    }
}

struct BrowseReturnThumbnailState {
    var displayedImages: [String]
    /// Legacy snapshot only; restore resolves selection by `currentImagePath`, not index.
    var currentIndex: Int
    var currentImagePath: String?
    var currentDirectory: String?
    var specificFilesActive: Bool
    var sortMode: String
    var sortReversed: Bool
    var thumbnailCellSize: Double
    var manualThumbnailSize: Bool
}

