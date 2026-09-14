import Foundation

/// Keeps `currentImagePath` present in `displayedImages` when the file exists on disk but
/// directory scans omit it (e.g. filename filter).
@MainActor
enum DisplayedImagesSync {
    static func ensureActiveImageListed(fileData: FileDataModel) {
        guard let raw = fileData.currentImagePath,
              let path = FileDataModel.normalizePath(raw),
              FileManager.default.fileExists(atPath: path) else { return }

        let images = fileData.getDisplayedImages()
        if images.contains(path) {
            if raw != path {
                fileData.setCurrentImagePath(path)
            }
            return
        }

        var merged = images
        merged.insert(path, at: 0)
        fileData.setDisplayedImages(merged)
        fileData.setCurrentImagePath(path)
    }
}
