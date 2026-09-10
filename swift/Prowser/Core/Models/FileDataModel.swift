import Foundation

/// Single source of truth for displayed files and current selection index.
/// Mirrors Python `FileDataModel`.
@Observable
@MainActor
final class FileDataModel {
    private(set) var displayedImages: [String] = []
    private(set) var currentImagePath: String?
    private(set) var currentDirectory: String?
    private(set) var currentIndex: Int = 0
    private(set) var currentViewMode: ViewMode = .thumbnail

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
            NotificationCenter.default.post(name: .prowserDisplayedImagesChanged, object: displayedImages)
            if currentIndex != oldIndex {
                NotificationCenter.default.post(name: .prowserCurrentIndexChanged, object: currentIndex)
            }
            if let currentImagePath {
                NotificationCenter.default.post(name: .prowserCurrentImageChanged, object: currentImagePath)
            }
        }
    }

    func setCurrentImagePath(_ path: String?) {
        guard let path else {
            currentImagePath = nil
            NotificationCenter.default.post(name: .prowserCurrentImageChanged, object: nil)
            return
        }
        guard let normalized = Self.normalizePath(path) else { return }
        currentImagePath = normalized
        if let index = displayedImages.firstIndex(of: normalized) {
            currentIndex = index
            NotificationCenter.default.post(name: .prowserCurrentIndexChanged, object: index)
        }
        NotificationCenter.default.post(name: .prowserCurrentImageChanged, object: normalized)
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
        NotificationCenter.default.post(name: .prowserCurrentIndexChanged, object: clamped)
        NotificationCenter.default.post(name: .prowserCurrentImageChanged, object: currentImagePath)
    }

    func setCurrentDirectory(_ path: String) {
        let normalized = Self.normalizePath(path)
        guard normalized != currentDirectory else { return }
        currentDirectory = normalized
        NotificationCenter.default.post(name: .prowserDirectoryChanged, object: normalized)
    }

    func setViewMode(_ mode: ViewMode) {
        guard mode != currentViewMode else { return }
        if mode == .thumbnail {
            syncCurrentIndexFromPath()
        }
        currentViewMode = mode
        NotificationCenter.default.post(name: .prowserViewModeChanged, object: mode.rawValue)
    }

    /// Align `currentIndex` with `currentImagePath` before showing the thumbnail grid.
    private func syncCurrentIndexFromPath() {
        guard let path = currentImagePath,
              let index = displayedImages.firstIndex(of: path) else { return }
        guard index != currentIndex else { return }
        currentIndex = index
        NotificationCenter.default.post(name: .prowserCurrentIndexChanged, object: index)
    }

    static func normalizePath(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
}

extension Notification.Name {
    static let prowserDisplayedImagesChanged = Notification.Name("prowser.displayedImagesChanged")
    static let prowserCurrentImageChanged = Notification.Name("prowser.currentImageChanged")
    static let prowserCurrentIndexChanged = Notification.Name("prowser.currentIndexChanged")
    static let prowserDirectoryChanged = Notification.Name("prowser.directoryChanged")
    static let prowserViewModeChanged = Notification.Name("prowser.viewModeChanged")
}
