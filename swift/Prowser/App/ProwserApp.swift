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

/// Coordinates directory scans and model updates.
@MainActor
final class DirectoryLoadCoordinator {
    private unowned let appState: AppState
    private var activeLoadGeneration = 0
    private var activeLoadTask: Task<Void, Never>?

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
        loadDirectory(directory, saveHistory: false, pinnedImagePath: normalizedTarget)

        appState.fileData.setViewMode(.browse)
        appState.clearBrowseReturnState()
        appState.scheduleDeferredMenuRefresh()
    }

    func loadDirectory(
        _ path: String,
        saveHistory: Bool,
        pinnedImagePath: String? = nil,
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

        let pin: String?
        if let explicit = pinnedImagePath.flatMap({ FileDataModel.normalizePath($0) }) {
            pin = explicit
        } else if appState.fileData.currentViewMode == .browse {
            pin = appState.fileData.currentImagePath
        } else {
            pin = nil
        }

        let snapshot = DirectoryLoadBackgroundWork.Snapshot(
            path: normalized,
            extensions: appState.config.imageExtensions,
            filterPattern: appState.filterSettings.filterPattern,
            sortModeRaw: appState.config.string(forKey: "sort_mode", default: "date"),
            sortReversed: appState.config.bool(forKey: "sort_reversed", default: false),
            useExifDate: appState.config.useExifDate
        )

        let useLoadingCanvas = !appState.hasCompletedInitialThumbnailDirectoryLoad
            && appState.fileData.currentViewMode == .thumbnail
            && pin == nil

        appState.isLoadingDirectory = true
        appState.showThumbnailDirectoryLoadingCanvas = useLoadingCanvas

        if useLoadingCanvas {
            appState.fileData.setDisplayedImages([])
            appState.fileData.setCurrentDirectory(normalized)
            appState.beginThumbnailDirectoryLoad()
        } else if pin != nil {
            appState.fileData.setCurrentDirectory(normalized)
            if let pin {
                appState.fileData.setCurrentImagePath(pin)
            }
        }

        activeLoadTask = Task { [weak self] in
            let images = await Task.detached(priority: .userInitiated) {
                DirectoryLoadBackgroundWork.scanAndSort(snapshot)
            }.value

            guard !Task.isCancelled else { return }
            self?.finishDirectoryLoad(
                generation: generation,
                path: normalized,
                images: images,
                pinnedPath: pin,
                onComplete: onComplete
            )
        }
    }

    private func finishDirectoryLoad(
        generation: Int,
        path: String,
        images: [String],
        pinnedPath: String?,
        onComplete: (() -> Void)?
    ) {
        guard generation == activeLoadGeneration else { return }
        appState.isLoadingDirectory = false
        if appState.showThumbnailDirectoryLoadingCanvas {
            appState.endThumbnailDirectoryLoad()
        }
        appState.noteInitialThumbnailDirectoryLoadCompleted()

        appState.fileData.setCurrentDirectory(path)
        appState.fileData.setDisplayedImages(images)
        if let pinnedPath, let normalized = FileDataModel.normalizePath(pinnedPath),
           images.contains(normalized) {
            appState.fileData.setCurrentImagePath(normalized)
        } else if let first = images.first {
            appState.fileData.setCurrentImagePath(first)
        } else {
            appState.fileData.setCurrentImagePath(nil)
        }
        DisplayedImagesSync.ensureActiveImageListed(
            fileData: appState.fileData,
            filterPattern: appState.filterSettings.filterPattern,
            isLoadingDirectory: false
        )
        appState.config.updateSetting("last_directory", value: path)
        appState.config.recordRecentDirectory(path)
        appState.eventBus.emit(.directoryLoaded, payload: .string(path))
        appState.watchCurrentDirectory()
        appState.persistRestoreState()
        appState.scheduleDeferredMenuRefresh()
        onComplete?()
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

