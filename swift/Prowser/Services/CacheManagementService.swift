import Foundation

/// Cache clear/scrub operations for the Settings → Caches tab (port of Python cache_manager).
@MainActor
enum CacheManagementService {
    struct CacheTotals {
        var thumbnails: Int64
        var metadata: Int64
        var imageRecognition: Int64

        var total: Int64 { thumbnails + metadata + imageRecognition }
    }

    struct ScrubResult {
        var thumbnailsRemoved: Int
        var imageRecognitionRemoved: Int
        var bytesReclaimed: Int64
    }

    static func cacheTotals(paths: ProfilePaths) -> CacheTotals {
        CacheTotals(
            thumbnails: directorySize(paths.thumbnailCacheDirectory),
            metadata: directorySize(paths.metadataCacheDirectory),
            imageRecognition: directorySize(paths.imageRecognitionCacheDirectory)
        )
    }

    static func clearThumbnailCache(paths: ProfilePaths) -> Int {
        removeContents(of: paths.thumbnailCacheDirectory)
    }

    static func clearFaceCache(paths: ProfilePaths) {
        FaceCacheService(profile: paths).clearAll()
    }

    static func clearImageRecognitionCache(paths: ProfilePaths, includeDownloadedModels: Bool) throws -> Int {
        let root = paths.imageRecognitionCacheDirectory
        var removed = 0
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return 0
        }
        for entry in entries {
            if entry.lastPathComponent == "models", !includeDownloadedModels { continue }
            if (try? fm.removeItem(at: entry)) != nil { removed += 1 }
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if includeDownloadedModels {
            try? ModelDownloadService.removeAllDownloadedModels(profile: paths)
        }
        return removed
    }

    static func clearAllCaches(paths: ProfilePaths) -> Int {
        let ir = (try? clearImageRecognitionCache(paths: paths, includeDownloadedModels: false)) ?? 0
        return clearThumbnailCache(paths: paths)
            + removeContents(of: paths.metadataCacheDirectory)
            + ir
    }

    static func scrubCaches(paths: ProfilePaths, cacheKeyForPath: [String: String]) -> ScrubResult {
        let before = cacheTotals(paths: paths)
        let thumbsRemoved = scrubThumbnailCache(
            paths.thumbnailCacheDirectory,
            knownImagePaths: Array(cacheKeyForPath.keys),
            cacheKeyForPath: cacheKeyForPath
        )
        let irRemoved = scrubImageRecognitionCache(paths: paths)
        let after = cacheTotals(paths: paths)
        return ScrubResult(
            thumbnailsRemoved: thumbsRemoved,
            imageRecognitionRemoved: irRemoved,
            bytesReclaimed: max(0, before.total - after.total)
        )
    }

    static func cacheSourceDirectories(paths: ProfilePaths) -> [String] {
        [
            paths.thumbnailCacheDirectory.path,
            paths.metadataCacheDirectory.path,
            paths.imageRecognitionCacheDirectory.path,
            paths.sharedFaceCacheDirectory.path,
        ]
    }

    private static func scrubImageRecognitionCache(paths: ProfilePaths) -> Int {
        let fm = FileManager.default
        let root = paths.imageRecognitionCacheDirectory
        var removed = 0
        if let subdirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            for subdir in subdirs {
                let isDir = (try? subdir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                guard isDir else { continue }
                removed += scrubFeatureCacheDirectory(subdir)
            }
        }
        guard let files = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return removed }
        for file in files where file.pathExtension == "fcache" {
            guard let data = try? Data(contentsOf: file),
                  let payload = try? JSONDecoder().decode(FeatureCacheScrubFile.self, from: data) else { continue }
            let kept = payload.items.filter { FileManager.default.fileExists(atPath: $0.path) }
            if kept.count != payload.items.count {
                if kept.isEmpty {
                    try? fm.removeItem(at: file)
                } else if let newData = try? JSONEncoder().encode(FeatureCacheScrubFile(items: kept)) {
                    try? newData.write(to: file, options: .atomic)
                }
                removed += payload.items.count - kept.count
            }
        }
        return removed
    }

    private static func scrubFeatureCacheDirectory(_ directory: URL) -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return 0 }
        var removed = 0
        for file in files where file.pathExtension == "fcache" {
            guard let data = try? Data(contentsOf: file),
                  let payload = try? JSONDecoder().decode(FeatureCacheScrubFile.self, from: data) else { continue }
            let kept = payload.items.filter { FileManager.default.fileExists(atPath: $0.path) }
            if kept.count != payload.items.count {
                if kept.isEmpty {
                    try? fm.removeItem(at: file)
                } else if let newData = try? JSONEncoder().encode(FeatureCacheScrubFile(items: kept)) {
                    try? newData.write(to: file, options: .atomic)
                }
                removed += payload.items.count - kept.count
            }
        }
        return removed
    }

    private struct FeatureCacheScrubItem: Codable {
        let path: String
        let mtime: Double?
        let size: Int?
        let feature: [Float]?
    }

    private struct FeatureCacheScrubFile: Codable {
        let items: [FeatureCacheScrubItem]
    }

    /// Remove thumbnail JPEGs whose cache key no longer matches an existing image path (Python scrub orphan pass).
    private static func scrubThumbnailCache(
        _ directory: URL,
        knownImagePaths: [String],
        cacheKeyForPath: [String: String]
    ) -> Int {
        let fm = FileManager.default
        let validKeys = Set(
            knownImagePaths.filter { fm.fileExists(atPath: $0) }.compactMap { cacheKeyForPath[$0] }
        )
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return 0
        }
        var removed = 0
        for file in files where file.pathExtension.lowercased() == "jpg" {
            let stem = file.deletingPathExtension().lastPathComponent
            guard let underscore = stem.lastIndex(of: "_") else {
                if (try? fm.removeItem(at: file)) != nil { removed += 1 }
                continue
            }
            let baseKey = String(stem[..<underscore])
            if !validKeys.contains(baseKey), (try? fm.removeItem(at: file)) != nil {
                removed += 1
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
