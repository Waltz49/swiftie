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
        if images == displayedImages { return }

        // Same membership, new order — paths are already canonical (skip O(n) standardizedFileURL).
        if Set(images) == Set(displayedImages) {
            let oldIndex = currentIndex
            displayedImages = images
            syncCurrentIndexFromPath()
            if notify {
                eventBridge?.displayedImagesChanged(displayedImages)
                if currentIndex != oldIndex {
                    eventBridge?.currentIndexChanged(currentIndex)
                }
                // Active file unchanged — omit `currentImageChanged` (Python `display_image` only on real changes).
            }
            return
        }

        let normalized = images.compactMap { Self.normalizePath($0) }
        guard normalized != displayedImages else { return }

        let oldIndex = currentIndex
        let priorPath = currentImagePath
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
                let pathChanged = priorPath.map { !Self.pathsReferToSameFile($0, currentImagePath) } ?? true
                if pathChanged {
                    eventBridge?.currentImageChanged(currentImagePath)
                }
            } else if priorPath != nil {
                eventBridge?.currentImageChanged(nil)
            }
        }
    }

    func setCurrentImagePath(_ path: String?) {
        guard let path else {
            guard currentImagePath != nil else { return }
            currentImagePath = nil
            eventBridge?.currentImageChanged(nil)
            return
        }
        guard let normalized = Self.normalizePath(path) else { return }
        if let existing = currentImagePath, Self.pathsReferToSameFile(existing, normalized) {
            if let index = Self.indexOfPath(normalized, in: displayedImages), index != currentIndex {
                currentIndex = index
                eventBridge?.currentIndexChanged(index)
            }
            return
        }
        currentImagePath = normalized
        if let index = Self.indexOfPath(normalized, in: displayedImages) {
            if index != currentIndex {
                currentIndex = index
                eventBridge?.currentIndexChanged(index)
            }
        }
        eventBridge?.currentImageChanged(normalized)
    }

    /// Index in `displayedImages` for a path (normalized equality).
    static func indexOfPath(_ path: String, in images: [String]) -> Int? {
        guard let normalized = normalizePath(path) else { return nil }
        return images.firstIndex(of: normalized)
    }

    func reconcileCurrentIndexWithPath() {
        syncCurrentIndexFromPath()
    }

    func setCurrentIndex(_ index: Int) {
        guard !displayedImages.isEmpty else {
            currentIndex = 0
            currentImagePath = nil
            return
        }
        let clamped = max(0, min(index, displayedImages.count - 1))
        let newPath = displayedImages[clamped]
        let oldIndex = currentIndex
        let priorPath = currentImagePath
        currentIndex = clamped
        currentImagePath = newPath
        if oldIndex != clamped {
            eventBridge?.currentIndexChanged(clamped)
        }
        let pathChanged = priorPath.map { !Self.pathsReferToSameFile($0, newPath) } ?? true
        if pathChanged {
            eventBridge?.currentImageChanged(currentImagePath)
        }
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

    /// Same inode on disk (case-insensitive volume safe).
    static func pathsReferToSameFile(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).standardizedFileURL == URL(fileURLWithPath: rhs).standardizedFileURL
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
