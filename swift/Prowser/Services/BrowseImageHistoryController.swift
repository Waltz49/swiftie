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
        history = history.filter { FileManager.default.fileExists(atPath: $0) }
        if history.count > Self.maxEntries {
            history = Array(history.prefix(Self.maxEntries))
        }
    }

    func touch(_ path: String) {
        guard let normalized = FileDataModel.normalizePath(path),
              FileManager.default.fileExists(atPath: normalized) else { return }
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
              FileManager.default.fileExists(atPath: normalized) else { return }

        let delayMS = appState.config.int(forKey: "browse_image_history_save_after_ms", default: 3000)
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
        if appState.fileData.currentViewMode != .browse {
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

        prune()
        let paths = history.filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else {
            appState.status.show("Browse image history is empty")
            return
        }

        appState.directoryHistory.saveCurrent(
            fileData: appState.fileData,
            config: appState.config,
            selection: appState.selection
        )
        appState.selection.clear()
        appState.config.updateSetting("sort_mode", value: SortMode.custom.rawValue)
        appState.config.updateSetting("sort_reversed", value: false)
        appState.setSpecificFilesActive(true)
        if let firstDirectory = paths.first.map { ($0 as NSString).deletingLastPathComponent } {
            appState.fileData.setCurrentDirectory(firstDirectory)
        }
        appState.fileData.setDisplayedImages(paths)
        appState.fileData.setCurrentIndex(0)
        appState.fileData.setCurrentImagePath(paths[0])
        appState.fileData.setViewMode(.thumbnail)
        appState.status.show("Image history (\(paths.count) images)")
    }

    /// ⌘; — swap F3 browse history [0]↔[1], then show the new first image in browse mode.
    func swapFirstTwoAndShow() {
        guard let appState else { return }
        guard appState.fileData.currentViewMode == .browse else { return }

        prune()
        guard history.count >= 2 else { return }
        history.swapAt(0, 1)

        let newFirst = history[0]
        guard FileManager.default.fileExists(atPath: newFirst) else { return }
        appState.openImageInBrowse(path: newFirst)
    }
}
