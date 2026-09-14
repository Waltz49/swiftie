import Foundation

/// Cache clear/scrub operations for the Settings → Caches tab (port of Python cache_manager).
@MainActor
enum CacheManagementService {
    struct CacheTotals {
        var thumbnails: Int64
        var metadata: Int64

        var total: Int64 { thumbnails + metadata }
    }

    struct ScrubResult {
        var thumbnailsRemoved: Int
        var bytesReclaimed: Int64
    }

    static func cacheTotals(paths: ProfilePaths) -> CacheTotals {
        CacheTotals(
            thumbnails: directorySize(paths.thumbnailCacheDirectory),
            metadata: directorySize(paths.metadataCacheDirectory)
        )
    }

    static func clearThumbnailCache(paths: ProfilePaths) -> Int {
        removeContents(of: paths.thumbnailCacheDirectory)
    }

    static func clearAllCaches(paths: ProfilePaths) -> Int {
        clearThumbnailCache(paths: paths)
            + removeContents(of: paths.metadataCacheDirectory)
    }

    static func scrubCaches(paths: ProfilePaths) -> ScrubResult {
        let before = cacheTotals(paths: paths)
        let thumbsRemoved = scrubThumbnailCache(paths.thumbnailCacheDirectory)
        let after = cacheTotals(paths: paths)
        return ScrubResult(
            thumbnailsRemoved: thumbsRemoved,
            bytesReclaimed: max(0, before.total - after.total)
        )
    }

    static func cacheSourceDirectories(paths: ProfilePaths) -> [String] {
        [
            paths.thumbnailCacheDirectory.path,
            paths.metadataCacheDirectory.path,
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
