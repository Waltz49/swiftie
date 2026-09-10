import AppKit
import Foundation

/// Thumbnail memory + disk cache. Port of `cache/image_cache.py` (incremental).
actor ThumbnailCache {
    private let thumbnailDirectory: URL
    private let appCacheDirectory: URL
    private var ignoreExifRotation: Bool
    private var memoryCache: [String: NSImage] = [:]
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
        storeInMemory(key: memoryKey, image: image)
        return image
    }

    func storeThumbnail(_ image: NSImage, for imagePath: String, size: Int) throws {
        let memoryKey = "\(cacheKey(for: imagePath))_\(size)"
        storeInMemory(key: memoryKey, image: image)

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            return
        }
        let url = diskURL(for: imagePath, size: size)
        try jpeg.write(to: url, options: .atomic)
    }

    /// Returns `CGImage` so callers on `@MainActor` can build `NSImage` without crossing a non-Sendable boundary.
    func generateThumbnail(for imagePath: String, size: Int) async -> CGImage? {
        if let cached = cachedThumbnail(for: imagePath, size: size),
           let cgImage = cached.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cgImage
        }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: imagePath) as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: size,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: !ignoreExifRotation,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        try? storeThumbnail(image, for: imagePath, size: size)
        return cgImage
    }

    private func storeInMemory(key: String, image: NSImage) {
        if memoryCache.count >= memoryLimit {
            memoryCache.removeValue(forKey: memoryCache.keys.first!)
        }
        memoryCache[key] = image
    }
}
