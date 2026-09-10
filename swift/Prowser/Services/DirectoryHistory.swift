import Foundation

/// Back/forward directory navigation. Port of `directory_history_handler.py` (simplified).
@MainActor
final class DirectoryHistory {
    struct Entry: Equatable {
        let directory: String
        let currentPath: String?
        let index: Int
    }

    private var backward: [Entry] = []
    private var forward: [Entry] = []
    private let maxSize = 20

    var canGoBack: Bool { !backward.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    func saveCurrent(fileData: FileDataModel) {
        guard let directory = fileData.currentDirectory else { return }
        let entry = Entry(
            directory: directory,
            currentPath: fileData.currentImagePath,
            index: fileData.currentIndex
        )
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

    func entry(from fileData: FileDataModel) -> Entry? {
        guard let directory = fileData.currentDirectory else { return nil }
        return Entry(
            directory: directory,
            currentPath: fileData.currentImagePath,
            index: fileData.currentIndex
        )
    }

    func applyEntry(_ entry: Entry, to fileData: FileDataModel) {
        if let path = entry.currentPath, fileData.displayedImages.contains(path) {
            fileData.setCurrentImagePath(path)
            fileData.setCurrentIndex(entry.index)
        }
    }
}
