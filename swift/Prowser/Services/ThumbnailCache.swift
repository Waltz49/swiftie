import AppKit
import Foundation
import ImageIO

/// Thumbnail memory + disk cache. Port of `cache/image_cache.py` (incremental).
actor ThumbnailCache {
    private let thumbnailDirectory: URL
    private let appCacheDirectory: URL
    private var ignoreExifRotation: Bool
    private var memoryCache: [String: NSImage] = [:]
    private var memoryKeysByPath: [String: Set<String>] = [:]
    private let memoryLimit = 500

    init(paths: ProfilePaths, ignoreExifRotation: Bool) {
        thumbnailDirectory = paths.thumbnailCacheDirectory
        appCacheDirectory = paths.imageCacheDirectory
        self.ignoreExifRotation = ignoreExifRotation
    }

    func updateExifSetting(ignore: Bool) {
        if ignore != ignoreExifRotation {
            ignoreExifRotation = ignore
            memoryCache.removeAll()
            memoryKeysByPath.removeAll()
        }
    }

    func invalidate(for imagePath: String) {
        let normalized = ThumbnailCacheKey.normalizeImagePath(imagePath)
        if let keys = memoryKeysByPath.removeValue(forKey: normalized) {
            for key in keys {
                memoryCache.removeValue(forKey: key)
            }
        }
    }

    func cacheKey(for imagePath: String) -> String {
        ThumbnailCacheKey.computeCacheKey(
            imagePath: imagePath,
            appCacheDir: appCacheDirectory.path,
            ignoreExifRotation: ignoreExifRotation
        )
    }

    func diskURL(for imagePath: String, size: Int) -> URL {
        let key = cacheKey(for: imagePath)
        return thumbnailDirectory.appendingPathComponent(
            ThumbnailCacheKey.diskFilename(cacheKey: key, size: size),
            isDirectory: false
        )
    }

    func cachedThumbnail(for imagePath: String, size: Int) -> NSImage? {
        let memoryKey = "\(cacheKey(for: imagePath))_\(size)"
        if let hit = memoryCache[memoryKey] {
            return hit
        }
        let url = diskURL(for: imagePath, size: size)
        guard let image = NSImage(contentsOf: url) else { return nil }
        storeInMemory(key: memoryKey, image: image, imagePath: imagePath)
        return image
    }

    func storeThumbnail(_ image: NSImage, for imagePath: String, size: Int) throws {
        let memoryKey = "\(cacheKey(for: imagePath))_\(size)"
        storeInMemory(key: memoryKey, image: image, imagePath: imagePath)

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            return
        }
        let url = diskURL(for: imagePath, size: size)
        try jpeg.write(to: url, options: .atomic)
    }

    struct GeneratedThumbnail: Sendable {
        let image: CGImage
        /// Original pixel size after EXIF orientation, matching Python `loader_metadata`.
        /// Zero when served from the thumbnail JPEG cache (that file is not the original).
        let originalWidth: Int
        let originalHeight: Int
    }

    /// Returns `CGImage` so callers on `@MainActor` can build `NSImage` without crossing a non-Sendable boundary.
    func generateThumbnail(for imagePath: String, size: Int) async -> CGImage? {
        await generateThumbnailResult(for: imagePath, size: size)?.image
    }

    func generateThumbnailResult(for imagePath: String, size: Int) async -> GeneratedThumbnail? {
        if let cached = cachedThumbnail(for: imagePath, size: size),
           let cgImage = cached.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return GeneratedThumbnail(image: cgImage, originalWidth: 0, originalHeight: 0)
        }
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(
            URL(fileURLWithPath: imagePath) as CFURL,
            sourceOptions as CFDictionary
        ) else {
            return nil
        }
        let dims = originalPixelSize(from: source)
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: size,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: !ignoreExifRotation,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        try? storeThumbnail(image, for: imagePath, size: size)
        return GeneratedThumbnail(
            image: cgImage,
            originalWidth: dims.width,
            originalHeight: dims.height
        )
    }

    private func originalPixelSize(from source: CGImageSource) -> (width: Int, height: Int) {
        let propertyOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, propertyOptions as CFDictionary) as? [CFString: Any],
              let rawWidth = props[kCGImagePropertyPixelWidth] as? Int,
              let rawHeight = props[kCGImagePropertyPixelHeight] as? Int else {
            return (0, 0)
        }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        if !ignoreExifRotation, (5...8).contains(orientation) {
            return (rawHeight, rawWidth)
        }
        return (rawWidth, rawHeight)
    }

    func statistics() -> (memoryCount: Int, diskCount: Int) {
        let diskCount = (try? FileManager.default.contentsOfDirectory(atPath: thumbnailDirectory.path).count) ?? 0
        return (memoryCache.count, diskCount)
    }

    /// Warm thumbnail disk cache for images in subdirectories (Python `cache_prepopulator.prepopulate_cache`).
    func prepopulateSubdirectories(rootDirectory: String, extensions: [String], maxDepth: Int = 4, size: Int = 256) async -> Int {
        let paths = Self.collectImagePathsRecursively(
            root: rootDirectory,
            extensions: extensions,
            maxDepth: maxDepth
        )
        var count = 0
        for path in paths {
            if await generateThumbnail(for: path, size: size) != nil {
                count += 1
            }
        }
        return count
    }

    private static func collectImagePathsRecursively(
        root: String,
        extensions: [String],
        maxDepth: Int,
        depth: Int = 0
    ) -> [String] {
        guard depth <= maxDepth else { return [] }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        let extSet = Set(
            extensions.map {
                let e = $0.lowercased()
                return e.hasPrefix(".") ? String(e.dropFirst()) : e
            }
        )
        var results: [String] = []
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        for entry in entries where !entry.hasPrefix(".") {
            let path = (root as NSString).appendingPathComponent(entry)
            var entryIsDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &entryIsDir) else { continue }
            if entryIsDir.boolValue {
                results.append(contentsOf: collectImagePathsRecursively(
                    root: path,
                    extensions: extensions,
                    maxDepth: maxDepth,
                    depth: depth + 1
                ))
            } else if extSet.contains((entry as NSString).pathExtension.lowercased()) {
                results.append(path)
            }
        }
        return results
    }

    private func storeInMemory(key: String, image: NSImage, imagePath: String) {
        if memoryCache.count >= memoryLimit {
            memoryCache.removeValue(forKey: memoryCache.keys.first!)
        }
        memoryCache[key] = image
        let normalized = ThumbnailCacheKey.normalizeImagePath(imagePath)
        memoryKeysByPath[normalized, default: []].insert(key)
    }
}
