import Foundation

/// Back/forward directory navigation. Port of `directory_history_handler.py` (simplified).
@MainActor
final class DirectoryHistory {
    struct Entry: Equatable {
        let directory: String?
        let currentPath: String?
        let index: Int
        let displayedImages: [String]
        let viewMode: ViewMode
        let sortMode: String
        let sortReversed: Bool
    }

    private var backward: [Entry] = []
    private var forward: [Entry] = []
    private let maxSize = 20

    var canGoBack: Bool { !backward.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    func saveCurrent(fileData: FileDataModel, config: AppConfig) {
        guard fileData.currentDirectory != nil || !fileData.displayedImages.isEmpty else { return }
        let entry = entry(from: fileData, config: config)
        if backward.last == entry { return }
        backward.append(entry)
        if backward.count > maxSize {
            backward.removeFirst()
        }
        forward.removeAll()
    }

    func goBack(current: Entry) -> Entry? {
        guard let previous = backward.popLast() else { return nil }
        forward.append(current)
        return previous
    }

    func goForward(current: Entry) -> Entry? {
        guard let next = forward.popLast() else { return nil }
        backward.append(current)
        return next
    }

    func entry(from fileData: FileDataModel, config: AppConfig) -> Entry {
        Entry(
            directory: fileData.currentDirectory,
            currentPath: fileData.currentImagePath,
            index: fileData.currentIndex,
            displayedImages: fileData.displayedImages,
            viewMode: fileData.currentViewMode,
            sortMode: config.string(forKey: "sort_mode", default: SortMode.date.rawValue),
            sortReversed: config.bool(forKey: "sort_reversed", default: false)
        )
    }

    func applyEntry(_ entry: Entry, to fileData: FileDataModel) {
        if let path = entry.currentPath, fileData.displayedImages.contains(path) {
            fileData.setCurrentImagePath(path)
            fileData.setCurrentIndex(entry.index)
        }
    }

    /// Clears back/forward stacks. Returns number of entries removed.
    func clearAll() -> Int {
        let count = backward.count + forward.count
        backward.removeAll()
        forward.removeAll()
        return count
    }
}
