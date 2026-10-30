import Foundation

/// Keeps `currentImagePath` present in `displayedImages` when the file exists on disk but
/// directory scans omit it (e.g. filename filter).
@MainActor
enum DisplayedImagesSync {
    static func ensureActiveImageListed(
        fileData: FileDataModel,
        filterPattern: String = "*",
        isLoadingDirectory: Bool = false
    ) {
        guard !isLoadingDirectory else { return }
        guard let raw = fileData.currentImagePath,
              let path = FileDataModel.normalizePath(raw),
              FileManager.default.fileExists(atPath: path),
              let currentDirectory = fileData.currentDirectory,
              FileDataModel.pathIsInDirectory(file: path, directory: currentDirectory) else { return }

        let basename = (path as NSString).lastPathComponent
        if !DirectoryScanner.matchesGlob(basename, pattern: filterPattern) {
            return
        }

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

    /// True when the thumbnail listing belongs to `currentDirectory` (empty list counts as matching).
    static func displayedImagesMatchCurrentDirectory(
        fileData: FileDataModel,
        specificFilesActive: Bool,
        referenceGraphActive: Bool
    ) -> Bool {
        if specificFilesActive || referenceGraphActive { return true }
        let images = fileData.displayedImages
        if images.isEmpty { return true }
        guard let directory = fileData.currentDirectory else { return true }
        for path in images {
            guard FileDataModel.pathIsInDirectory(file: path, directory: directory) else {
                return false
            }
        }
        return true
    }
}
