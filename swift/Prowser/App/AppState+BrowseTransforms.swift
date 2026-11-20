import Foundation

extension AppState {
    /// Refresh browse canvas and thumbnails after a session-only transform change (no file I/O).
    func refreshBrowseImageTransformDisplay(for path: String) {
        let active = fileData.currentImagePath.map(BrowseImageSessionTransform.canonicalPath)
        let changed = BrowseImageSessionTransform.canonicalPath(path)
        if active == changed {
            browseImageHost?.noteSessionTransformChanged()
        }
        thumbnailGridHost?.setNeedsDisplay(thumbnailGridHost?.bounds ?? .zero)
    }
}