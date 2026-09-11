import Foundation

/// Cache clear/scrub operations for the Settings → Caches tab (port of Python cache_manager).
@MainActor
enum CacheManagementService {
    struct CacheTotals {
        var thumbnails: Int64
        var similarity: Int64
        var search: Int64

        var total: Int64 { thumbnails + similarity + search }
    }

    struct ScrubResult {
        var thumbnailsRemoved: Int
        var recognitionRemoved: Int
        var bytesReclaimed: Int64
    }

    static func cacheTotals(paths: ProfilePaths) -> CacheTotals {
        CacheTotals(
            thumbnails: directorySize(paths.thumbnailCacheDirectory),
            similarity: directorySize(paths.imageRecognitionCacheDirectory.appendingPathComponent("cnn")),
            search: directorySize(paths.imageRecognitionCacheDirectory.appendingPathComponent("clip"))
        )
    }

    static func clearThumbnailCache(paths: ProfilePaths) -> Int {
        removeContents(of: paths.thumbnailCacheDirectory)
    }

    static func clearImageRecognitionCache(paths: ProfilePaths) -> Int {
        let root = paths.imageRecognitionCacheDirectory
        var removed = 0
        for sub in ["cnn", "clip", "features"] {
            removed += removeContents(of: root.appendingPathComponent(sub, isDirectory: true))
        }
        return removed
    }

    static func clearFaceCache(paths: ProfilePaths, dataDirectory: URL) -> Int {
        var removed = 0
        let faceCache = paths.imageRecognitionCacheDirectory.appendingPathComponent("face_cache", isDirectory: true)
        let dataDir = faceCache.appendingPathComponent("data", isDirectory: true)
        removed += removeContents(of: dataDir)
        let index = faceCache.appendingPathComponent("index.json")
        if FileManager.default.fileExists(atPath: index.path) {
            try? FileManager.default.removeItem(at: index)
            removed += 1
        }
        let sampleDir = dataDirectory.appendingPathComponent("face_sample_thumbs", isDirectory: true)
        removed += removeContents(of: sampleDir)
        return removed
    }

    static func clearAllCaches(paths: ProfilePaths, dataDirectory: URL) -> Int {
        clearThumbnailCache(paths: paths)
        + clearImageRecognitionCache(paths: paths)
        + clearFaceCache(paths: paths, dataDirectory: dataDirectory)
        + removeContents(of: paths.metadataCacheDirectory)
    }

    static func scrubCaches(paths: ProfilePaths) -> ScrubResult {
        var thumbsRemoved = 0
        var recRemoved = 0
        let before = cacheTotals(paths: paths)
        thumbsRemoved = scrubThumbnailCache(paths.thumbnailCacheDirectory)
        recRemoved = scrubRecognitionCache(paths.imageRecognitionCacheDirectory)
        let after = cacheTotals(paths: paths)
        return ScrubResult(
            thumbnailsRemoved: thumbsRemoved,
            recognitionRemoved: recRemoved,
            bytesReclaimed: max(0, before.total - after.total)
        )
    }

    static func cacheSourceDirectories(paths: ProfilePaths) -> [String] {
        [
            paths.thumbnailCacheDirectory.path,
            paths.metadataCacheDirectory.path,
            paths.imageRecognitionCacheDirectory.path,
        ]
    }

    private static func scrubThumbnailCache(_ directory: URL) -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return 0
        }
        var removed = 0
        for file in files {
            guard let name = file.lastPathComponent.components(separatedBy: "_").first else { continue }
            let imagePath = name.hasPrefix("/") ? name : "/" + name
            if !fm.fileExists(atPath: imagePath) {
                if (try? fm.removeItem(at: file)) != nil { removed += 1 }
            }
        }
        return removed
    }

    private static func scrubRecognitionCache(_ directory: URL) -> Int {
        var removed = 0
        for sub in ["cnn", "clip"] {
            let subdir = directory.appendingPathComponent(sub, isDirectory: true)
            guard let files = try? FileManager.default.contentsOfDirectory(at: subdir, includingPropertiesForKeys: nil) else {
                continue
            }
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let imagePath = json["path"] as? String else { continue }
                if !FileManager.default.fileExists(atPath: imagePath) {
                    if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
                }
            }
        }
        return removed
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    @discardableResult
    private static func removeContents(of directory: URL) -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return 0
        }
        var removed = 0
        for file in files {
            if (try? fm.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }
}
