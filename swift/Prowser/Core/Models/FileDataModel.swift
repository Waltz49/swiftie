import Foundation

/// Single source of truth for displayed files and current selection index.
/// Mirrors Python `FileDataModel`.
@Observable
@MainActor
final class FileDataModel {
    private let eventBridge: ModelEventBridge?

    private(set) var displayedImages: [String] = []
    private(set) var currentImagePath: String?
    private(set) var currentDirectory: String?
    private(set) var currentIndex: Int = 0
    private(set) var currentViewMode: ViewMode = .thumbnail

    init(eventBridge: ModelEventBridge? = nil) {
        self.eventBridge = eventBridge
    }

    func getDisplayedImages() -> [String] { displayedImages }

    func setDisplayedImages(_ images: [String], notify: Bool = true) {
        let normalized = images.compactMap { Self.normalizePath($0) }
        guard normalized != displayedImages else { return }

        let oldIndex = currentIndex
        displayedImages = normalized

        if displayedImages.isEmpty {
            currentIndex = 0
            currentImagePath = nil
        } else if currentIndex >= displayedImages.count {
            currentIndex = displayedImages.count - 1
            currentImagePath = displayedImages[currentIndex]
        } else if let path = currentImagePath, !displayedImages.contains(path) {
            currentImagePath = displayedImages[currentIndex]
        }

        if notify {
            eventBridge?.displayedImagesChanged(displayedImages)
            if currentIndex != oldIndex {
                eventBridge?.currentIndexChanged(currentIndex)
            }
            if let currentImagePath {
                eventBridge?.currentImageChanged(currentImagePath)
            }
        }
    }

    func setCurrentImagePath(_ path: String?) {
        guard let path else {
            currentImagePath = nil
            eventBridge?.currentImageChanged(nil)
            return
        }
        guard let normalized = Self.normalizePath(path) else { return }
        currentImagePath = normalized
        if let index = displayedImages.firstIndex(of: normalized) {
            currentIndex = index
            eventBridge?.currentIndexChanged(index)
        }
        eventBridge?.currentImageChanged(normalized)
    }

    func setCurrentIndex(_ index: Int) {
        guard !displayedImages.isEmpty else {
            currentIndex = 0
            currentImagePath = nil
            return
        }
        let clamped = max(0, min(index, displayedImages.count - 1))
        currentIndex = clamped
        currentImagePath = displayedImages[clamped]
        eventBridge?.currentIndexChanged(clamped)
        eventBridge?.currentImageChanged(currentImagePath)
    }

    func setCurrentDirectory(_ path: String) {
        let normalized = Self.normalizePath(path)
        guard normalized != currentDirectory else { return }
        currentDirectory = normalized
        if let normalized {
            eventBridge?.directoryChanged(normalized)
        }
    }

    func setViewMode(_ mode: ViewMode) {
        guard mode != currentViewMode else { return }
        if mode == .thumbnail {
            syncCurrentIndexFromPath()
        }
        currentViewMode = mode
        eventBridge?.viewModeChanged(mode.rawValue)
    }

    /// Align `currentIndex` with `currentImagePath` before showing the thumbnail grid.
    private func syncCurrentIndexFromPath() {
        guard let path = currentImagePath,
              let index = displayedImages.firstIndex(of: path) else { return }
        guard index != currentIndex else { return }
        currentIndex = index
        eventBridge?.currentIndexChanged(index)
    }

    static func normalizePath(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    /// Parent directory of `path`, normalized (for “does this file belong in this folder?” checks).
    static func parentDirectory(of path: String) -> String? {
        guard let normalized = normalizePath(path) else { return nil }
        return URL(fileURLWithPath: normalized).deletingLastPathComponent().standardizedFileURL.path
    }

    static func pathIsInDirectory(file: String, directory: String) -> Bool {
        guard let dir = normalizePath(directory),
              let parent = parentDirectory(of: file) else { return false }
        return parent == dir
    }
}
