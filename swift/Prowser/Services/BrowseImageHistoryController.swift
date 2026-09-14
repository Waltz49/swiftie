import Foundation

/// Recent images viewed in browse mode (F3). Port of Python `browse_image_history`.
@MainActor
final class BrowseImageHistoryController {
    static let maxEntries = 60

    private weak var appState: AppState?
    private var history: [String] = []
    private var debounceTask: Task<Void, Never>?
    private var pendingPath: String?

    func bind(_ appState: AppState) {
        self.appState = appState
    }

    var hasEntries: Bool {
        prune()
        return !history.isEmpty
    }

    func prune() {
        history = history.filter { Self.isExistingImageFile($0) }
        if history.count > Self.maxEntries {
            history = Array(history.prefix(Self.maxEntries))
        }
    }

    func touch(_ path: String) {
        guard let normalized = FileDataModel.normalizePath(path),
              Self.isExistingImageFile(normalized) else { return }
        if let index = history.firstIndex(of: normalized) {
            history.remove(at: index)
        }
        history.insert(normalized, at: 0)
        if history.count > Self.maxEntries {
            history.removeLast(history.count - Self.maxEntries)
        }
    }

    func cancelPending() {
        debounceTask?.cancel()
        debounceTask = nil
        pendingPath = nil
    }

    func scheduleRecord(path: String) {
        guard let appState else { return }
        cancelPending()
        guard appState.fileData.currentViewMode == .browse else { return }
        guard let normalized = FileDataModel.normalizePath(path),
              Self.isExistingImageFile(normalized) else { return }

        let delayMS = max(0, min(5000, appState.config.int(forKey: "browse_image_history_save_after_ms", default: 3000)))
        if delayMS <= 0 {
            touch(normalized)
            return
        }

        pendingPath = normalized
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delayMS) * 1_000_000)
            guard !Task.isCancelled else { return }
            guard let appState = self.appState,
                  appState.fileData.currentViewMode == .browse,
                  appState.fileData.currentImagePath == normalized else { return }
            self.touch(normalized)
            self.pendingPath = nil
        }
    }

    func onViewModeChanged() {
        guard let appState else { return }
        if appState.fileData.currentViewMode == .browse {
            // Python schedules from display_image whenever browse is showing, including
            // Return/F into the already-highlighted file (no current-path change).
            if let path = appState.fileData.currentImagePath {
                scheduleRecord(path: path)
            }
        } else {
            cancelPending()
        }
    }

    func onCurrentImageChanged(_ path: String?) {
        guard let appState, appState.fileData.currentViewMode == .browse else {
            cancelPending()
            return
        }
        guard let path else {
            cancelPending()
            return
        }
        scheduleRecord(path: path)
    }

    /// F3 — show recent browse images as a custom-sorted thumbnail list (Esc restores via history).
    func openHistory() {
        guard let appState else { return }
        let mode = appState.fileData.currentViewMode
        guard mode == .browse || mode == .thumbnail else { return }

        KeyboardInputTracer.log(
            "F3 openHistory mode=\(mode.rawValue) stored=\(history.count)",
            config: appState.config
        )

        prune()
        let paths = history.filter { Self.isExistingImageFile($0) }
        guard !paths.isEmpty else {
            return
        }

        appState.directoryHistory.saveCurrent(
            fileData: appState.fileData,
            config: appState.config,
            selection: appState.selection
        )
        // Leaving browse would restore stashed directory thumbs and clobber this level.
        appState.clearBrowseReturnState()
        appState.selection.clear()
        appState.config.updateSetting("sort_mode", value: SortMode.custom.rawValue)
        appState.config.updateSetting("sort_reversed", value: false)
        let directory = URL(fileURLWithPath: paths[0]).deletingLastPathComponent().path
        appState.setSpecificFilesActive(true)
        appState.fileData.setCurrentDirectory(directory)
        appState.fileData.setDisplayedImages(paths)
        appState.fileData.setCurrentIndex(0)
        appState.fileData.setCurrentImagePath(paths[0])
        appState.fileData.setViewMode(.thumbnail)
        appState.eventBus.emit(.directoryLoaded, payload: .string(directory))
        appState.watchCurrentDirectory()
        appState.menuRefresh.refreshAll()
    }

    /// ⌘; — swap F3 browse history [0]↔[1], then show the new first image in browse mode.
    func swapFirstTwoAndShow() {
        guard let appState else { return }
        guard appState.fileData.currentViewMode == .browse else { return }

        prune()
        guard history.count >= 2 else { return }
        history.swapAt(0, 1)

        let newFirst = history[0]
        guard Self.isExistingImageFile(newFirst) else { return }
        appState.openImageInBrowse(path: newFirst)
    }

    /// Python `os.path.isfile` — skip directories and missing paths.
    private static func isExistingImageFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }
}
