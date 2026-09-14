import AppKit
import Photos

/// Load browse images from Photos Library paths when direct file I/O is blocked (macOS TCC).
/// Call from the main thread (browse view, app launch).
enum PhotosLibraryBrowseLoader {
    static func isPhotosLibraryPath(_ path: String) -> Bool {
        RenamePrefixPlanner.isInsidePhotosLibrary(path)
    }

    /// Call after restoring a Photos path so the system can show the privacy prompt before browse.
    @discardableResult
    static func requestAccessIfNeeded(for path: String?) -> Bool {
        guard let path, isPhotosLibraryPath(path) else { return true }
        return ensureAuthorization(requestIfNeeded: true)
    }

    static func loadImage(from path: String) -> NSImage? {
        guard isPhotosLibraryPath(path) else { return nil }
        guard ensureAuthorization(requestIfNeeded: true) else {
            return nil
        }
        guard let asset = resolveAsset(for: path) else { return nil }
        return requestFullImage(for: asset)
    }

    static func blockedUserMessage() -> String {
        """
        macOS blocked reading this Photos library file.

        Allow Prowser under System Settings → Privacy & Security → Photos,
        or grant Full Disk Access to Prowser.app.
        """
    }

    static func isAccessBlocked(for path: String) -> Bool {
        isPhotosLibraryPath(path) && !ensureAuthorization(requestIfNeeded: false)
    }

    private static func ensureAuthorization(requestIfNeeded: Bool) -> Bool {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined, requestIfNeeded {
            let sem = DispatchSemaphore(value: 0)
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                status = newStatus
                sem.signal()
            }
            if Thread.isMainThread {
                while sem.wait(timeout: .now() + 0.05) == .timedOut {
                    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
                }
            } else {
                sem.wait()
            }
        }
        return status == .authorized || status == .limited
    }

    private static func resolveAsset(for path: String) -> PHAsset? {
        let fileURL = URL(fileURLWithPath: path)
        let uuid = fileURL.deletingPathExtension().lastPathComponent
        let filename = fileURL.lastPathComponent

        let localIdCandidates = [
            uuid,
            "\(uuid)/L0/001",
            "\(uuid)/L0/000",
        ]
        for localId in localIdCandidates {
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil)
            if let asset = fetched.firstObject {
                return asset
            }
        }

        let nameOptions = PHFetchOptions()
        nameOptions.fetchLimit = 1
        nameOptions.predicate = NSPredicate(format: "filename == %@", filename)
        if let asset = PHAsset.fetchAssets(with: .image, options: nameOptions).firstObject {
            return asset
        }

        let uuidOptions = PHFetchOptions()
        uuidOptions.fetchLimit = 20
        uuidOptions.predicate = NSPredicate(format: "filename ENDSWITH %@", uuid)
        let suffixMatches = PHAsset.fetchAssets(with: .image, options: uuidOptions)
        for index in 0..<suffixMatches.count {
            let asset = suffixMatches.object(at: index)
            if asset.localIdentifier.hasPrefix(uuid) {
                return asset
            }
        }
        return nil
    }

    private static func requestFullImage(for asset: PHAsset) -> NSImage? {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none
        options.isNetworkAccessAllowed = true
        var image: NSImage?
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .default,
            options: options
        ) { result, _ in
            image = result
        }
        return image
    }
}
