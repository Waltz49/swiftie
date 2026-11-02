import Foundation

/// Cache clear/scrub operations for the Settings → Caches tab (port of Python cache_manager).
@MainActor
enum CacheManagementService {
    struct CacheTotals {
        var thumbnails: Int64
        var metadata: Int64
        /// CNN/CLIP/Vision features and indexes (cleared by **Clear Image Rec**).
        var imageRecognition: Int64
        /// Core ML bundles under `models/` (kept when clearing image-rec features).
        var searchModels: Int64

        var total: Int64 { thumbnails + metadata + imageRecognition + searchModels }
    }

    struct ScrubResult {
        var thumbnailsRemoved: Int
        var imageRecognitionRemoved: Int
        var bytesReclaimed: Int64
    }

    static func cacheTotals(paths: ProfilePaths) -> CacheTotals {
        let irRoot = paths.imageRecognitionCacheDirectory
        return CacheTotals(
            thumbnails: directorySize(paths.thumbnailCacheDirectory),
            metadata: directorySize(paths.metadataCacheDirectory),
            imageRecognition: imageRecognitionFeatureCacheSize(root: irRoot),
            searchModels: directorySize(irRoot.appendingPathComponent("models", isDirectory: true))
        )
    }

    /// Partial totals for unit tests (image-rec root only).
    static func cacheTotals(imageRecognitionRoot: URL) -> CacheTotals {
        CacheTotals(
            thumbnails: 0,
            metadata: 0,
            imageRecognition: imageRecognitionFeatureCacheSize(root: imageRecognitionRoot),
            searchModels: directorySize(
                imageRecognitionRoot.appendingPathComponent("models", isDirectory: true)
            )
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

    static func scrubCaches(
        paths: ProfilePaths,
        cacheKeyForPath: [String: String],
        targetThumbnailPixelSize: Int
    ) -> ScrubResult {
        let before = cacheTotals(paths: paths)
        let thumbsRemoved = scrubThumbnailCache(
            paths.thumbnailCacheDirectory,
            cacheKeyForPath: cacheKeyForPath,
            targetThumbnailPixelSize: targetThumbnailPixelSize
        )
        let irRemoved = scrubImageRecognitionCache(paths: paths)
        let after = cacheTotals(paths: paths)
        return ScrubResult(
            thumbnailsRemoved: thumbsRemoved,
            imageRecognitionRemoved: irRemoved,
            bytesReclaimed: max(0, before.total - after.total)
        )
    }

    /// Pixel size to keep on disk during scrub (Python `MIN_THUMBNAIL_SIZE`, or manual `thumbnail_cell_size`).
    static func scrubTargetThumbnailPixelSize(config: AppConfig) -> Int {
        if config.bool(forKey: "manual_thumbnail_size", default: false) {
            let raw = config.double(forKey: "thumbnail_cell_size", default: ThumbnailLayout.defaultCellSize)
            let clamped = min(
                ThumbnailLayout.maxCellSize,
                max(ThumbnailLayout.minCellSize, CGFloat(raw))
            )
            return Int(clamped.rounded())
        }
        return ThumbnailGridLayoutService.minThumbnailSize
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

    /// Remove orphan thumbnail JPEGs and any size other than ``targetThumbnailPixelSize`` (Python scrub pass).
    /// Exposed for unit tests (`@testable import Prowser`).
    static func scrubThumbnailCache(
        _ directory: URL,
        cacheKeyForPath: [String: String],
        targetThumbnailPixelSize: Int
    ) -> Int {
        let fm = FileManager.default
        let validKeys = Set(
            cacheKeyForPath.keys
                .filter { fm.fileExists(atPath: $0) }
                .compactMap { cacheKeyForPath[$0] }
        )
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return 0
        }
        var removed = 0
        for file in files where file.pathExtension.lowercased() == "jpg" {
            let stem = file.deletingPathExtension().lastPathComponent
            guard let underscore = stem.lastIndex(of: "_"),
                  let size = Int(stem[stem.index(after: underscore)...]) else {
                if (try? fm.removeItem(at: file)) != nil { removed += 1 }
                continue
            }
            let baseKey = String(stem[..<underscore])
            let wrongSize = size != targetThumbnailPixelSize
            let orphan = !validKeys.contains(baseKey)
            if wrongSize || orphan, (try? fm.removeItem(at: file)) != nil {
                removed += 1
            }
        }
        return removed
    }

    /// Size of everything under the Swift image-rec root except downloaded Core ML `models/`.
    private static func imageRecognitionFeatureCacheSize(root: URL) -> Int64 {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return 0
        }
        var total: Int64 = 0
        for entry in entries where entry.lastPathComponent != "models" {
            total += entryByteSize(entry)
        }
        return total
    }

    private static func entryByteSize(_ url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if isDirectory.boolValue {
            return directorySize(url)
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Int64(size)
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
