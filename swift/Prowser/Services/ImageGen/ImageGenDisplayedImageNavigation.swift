import Foundation

/// Adjacent index in ``FileDataModel/displayedImages`` (Python ``navigate_source_image_at`` / ``_adjacent_displayed_path``).
@MainActor
enum ImageGenDisplayedImageNavigation {
    static func indexInDisplayedList(path: String, images: [String]) -> Int? {
        FileDataModel.indexOfPath(path, in: images)
            ?? images.firstIndex(where: { FileDataModel.pathsReferToSameFile(path, $0) })
    }

    static func adjacentIndex(from index: Int, delta: Int, count: Int, wrapAround: Bool) -> Int? {
        guard count > 0, index >= 0, index < count else { return nil }
        if delta < 0 {
            if index > 0 { return index - 1 }
            if wrapAround, count > 1 { return count - 1 }
            return nil
        }
        if index < count - 1 { return index + 1 }
        if wrapAround, count > 1 { return 0 }
        return nil
    }

    static func canStep(from index: Int, delta: Int, count: Int, wrapAround: Bool) -> Bool {
        adjacentIndex(from: index, delta: delta, count: count, wrapAround: wrapAround) != nil
    }
}
