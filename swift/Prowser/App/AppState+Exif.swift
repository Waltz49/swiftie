import Foundation

extension AppState {
    /// Port of Python ``FILE_METADATA_CHANGED`` after EXIF / metadata cache invalidation.
    func notifyFileMetadataChanged(path: String) {
        metadataCache.invalidate(path: path)
        eventBus.emit(.fileMetadataChanged, payload: .string(path))
    }

    func installExifMetadataChangeHooks() {
        ExifService.didUpdateUserCommentAtPath = { [weak self] path in
            self?.notifyFileMetadataChanged(path: path)
        }
    }
}
