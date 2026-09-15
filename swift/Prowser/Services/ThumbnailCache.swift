import AppKit
import Foundation
import ImageIO

/// Thumbnail memory + disk cache. Port of `cache/image_cache.py` (incremental).
actor ThumbnailCache {
    private struct MemoryEntry {
        let image: NSImage
        var lastUsed: UInt64
        let pixelSize: Int
    }

    private let thumbnailDirectory: URL
    private let appCacheDirectory: URL
    private var ignoreExifRotation: Bool
    private var memoryCache: [String: MemoryEntry] = [:]
    private var memoryKeysByPath: [String: Set<String>] = [:]
    private var mtimeStatCache: [String: (mtime: Int?, cachedAt: Date)] = [:]
    private var lruCounter: UInt64 = 0
    private let memoryLimit = 12_000
    private let statCacheMaxAge: TimeInterval = 60
    private let statCacheMaxEntries = 10_000
    private var inflightGenerations: [String: Task<GeneratedThumbnail?, Never>] = [:]
    private let decodePool = ThumbnailDecodePool(maxConcurrent: 4)

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
            mtimeStatCache.removeAll()
        }
    }

    func invalidate(for imagePath: String) {
        let normalized = ThumbnailCacheKey.normalizeImagePath(imagePath)
        mtimeStatCache.removeValue(forKey: normalized)
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
            ignoreExifRotation: ignoreExifRotation,
            mtime: resolvedMtime(for: imagePath)
        )
    }

    func diskURL(for imagePath: String, size: Int) -> URL {
        let key = cacheKey(for: imagePath)
        return thumbnailDirectory.appendingPathComponent(
            ThumbnailCacheKey.diskFilename(cacheKey: key, size: size),
            isDirectory: false
        )
    }

    /// Cache lookup only (no generation). Returns `CGImage` so `@MainActor` callers
    /// can build `NSImage` without crossing a non-Sendable boundary.
    func cachedThumbnail(for imagePath: String, size: Int) -> CGImage? {
        let memoryKey = memoryKey(for: imagePath, size: size)
        return cachedThumbnailResult(memoryKey: memoryKey, imagePath: imagePath, size: size)?.image
    }

    func storeThumbnail(_ image: NSImage, for imagePath: String, size: Int) throws {
        let memoryKey = memoryKey(for: imagePath, size: size)
        storeInMemory(key: memoryKey, image: image, imagePath: imagePath, pixelSize: size)

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
        let memoryKey = memoryKey(for: imagePath, size: size)
        if let cached = cachedThumbnailResult(memoryKey: memoryKey, imagePath: imagePath, size: size) {
            return cached
        }
        if let scaled = scaledDownFromLarger(imagePath: imagePath, size: size) {
            return scaled
        }

        if let existing = inflightGenerations[memoryKey] {
            return await existing.value
        }

        let ignoreExif = ignoreExifRotation
        let task = Task<GeneratedThumbnail?, Never> {
            await decodePool.generate(
                imagePath: imagePath,
                size: size,
                ignoreExifRotation: ignoreExif
            )
        }
        inflightGenerations[memoryKey] = task
        let generated = await task.value
        inflightGenerations.removeValue(forKey: memoryKey)

        guard let generated else { return nil }
        let image = NSImage(cgImage: generated.image, size: NSSize(width: generated.image.width, height: generated.image.height))
        try? await storeThumbnailOffDiskIO(image, for: imagePath, size: size, memoryKey: memoryKey)
        return generated
    }

    private func storeThumbnailOffDiskIO(
        _ image: NSImage,
        for imagePath: String,
        size: Int,
        memoryKey: String
    ) async throws {
        storeInMemory(key: memoryKey, image: image, imagePath: imagePath, pixelSize: size)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            return
        }
        let url = diskURL(for: imagePath, size: size)
        try await decodePool.writeJPEG(jpeg, to: url)
    }

    private func cachedThumbnailResult(memoryKey: String, imagePath: String, size: Int) -> GeneratedThumbnail? {
        if let image = touchMemory(key: memoryKey),
           let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return GeneratedThumbnail(image: cgImage, originalWidth: 0, originalHeight: 0)
        }
        let url = diskURL(for: imagePath, size: size)
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        storeInMemory(key: memoryKey, image: image, imagePath: imagePath, pixelSize: size)
        return GeneratedThumbnail(image: cgImage, originalWidth: 0, originalHeight: 0)
    }

    private func scaledDownFromLarger(imagePath: String, size: Int) -> GeneratedThumbnail? {
        let normalized = ThumbnailCacheKey.normalizeImagePath(imagePath)
        guard let keys = memoryKeysByPath[normalized] else { return nil }
        var bestKey: String?
        var bestSize = Int.max
        for key in keys {
            guard let cachedSize = parseSize(fromMemoryKey: key), cachedSize > size else { continue }
            if cachedSize < bestSize, memoryCache[key] != nil {
                bestSize = cachedSize
                bestKey = key
            }
        }
        if let bestKey, let entry = memoryCache[bestKey],
           let scaled = scaleImage(entry.image, toMaxPixel: size),
           let cgImage = scaled.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let memoryKey = memoryKey(for: imagePath, size: size)
            storeInMemory(key: memoryKey, image: scaled, imagePath: imagePath, pixelSize: size)
            return GeneratedThumbnail(image: cgImage, originalWidth: 0, originalHeight: 0)
        }

        let base = cacheKey(for: imagePath)
        guard let filenames = try? FileManager.default.contentsOfDirectory(atPath: thumbnailDirectory.path) else {
            return nil
        }
        var bestDiskSize = 0
        var bestDiskURL: URL?
        let prefix = "\(base)_"
        for filename in filenames where filename.hasPrefix(prefix) && filename.hasSuffix(".jpg") {
            guard let cachedSize = parseSize(fromDiskFilename: filename, prefix: prefix) else { continue }
            if cachedSize >= size && cachedSize > bestDiskSize {
                bestDiskSize = cachedSize
                bestDiskURL = thumbnailDirectory.appendingPathComponent(filename)
            }
        }
        guard let url = bestDiskURL,
              let image = NSImage(contentsOf: url),
              let scaled = scaleImage(image, toMaxPixel: size),
              let cgImage = scaled.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let memoryKey = memoryKey(for: imagePath, size: size)
        storeInMemory(key: memoryKey, image: scaled, imagePath: imagePath, pixelSize: size)
        return GeneratedThumbnail(image: cgImage, originalWidth: 0, originalHeight: 0)
    }

    private func scaleImage(_ image: NSImage, toMaxPixel size: Int) -> NSImage? {
        let proposed = image.size
        guard proposed.width > 0, proposed.height > 0 else { return nil }
        let scale = min(Double(size) / proposed.width, Double(size) / proposed.height, 1)
        let drawSize = NSSize(width: proposed.width * scale, height: proposed.height * scale)
        let scaled = NSImage(size: drawSize)
        scaled.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: drawSize),
            from: NSRect(origin: .zero, size: proposed),
            operation: .copy,
            fraction: 1
        )
        scaled.unlockFocus()
        return scaled
    }

    private func parseSize(fromMemoryKey key: String) -> Int? {
        guard let underscore = key.lastIndex(of: "_") else { return nil }
        return Int(key[key.index(after: underscore)...])
    }

    private func parseSize(fromDiskFilename filename: String, prefix: String) -> Int? {
        let stem = filename.dropFirst(prefix.count).dropLast(4)
        return Int(stem)
    }

    private func memoryKey(for imagePath: String, size: Int) -> String {
        "\(cacheKey(for: imagePath))_\(size)"
    }

    private func resolvedMtime(for imagePath: String) -> Int? {
        let pathStr = ThumbnailCacheKey.normalizeImagePath(imagePath)
        if ThumbnailCacheKey.isPathInAppCacheDirectory(imagePath: pathStr, appCacheDir: appCacheDirectory.path) {
            return nil
        }
        let now = Date()
        if let cached = mtimeStatCache[pathStr],
           now.timeIntervalSince(cached.cachedAt) < statCacheMaxAge {
            return cached.mtime
        }
        let mtime: Int?
        if let attrs = try? FileManager.default.attributesOfItem(atPath: pathStr),
           let mtimeNumber = attrs[.modificationDate] as? Date {
            mtime = Int(mtimeNumber.timeIntervalSince1970)
        } else {
            mtime = nil
        }
        mtimeStatCache[pathStr] = (mtime, now)
        if mtimeStatCache.count > statCacheMaxEntries {
            let dropCount = statCacheMaxEntries / 10
            for key in mtimeStatCache.keys.prefix(dropCount) {
                mtimeStatCache.removeValue(forKey: key)
            }
        }
        return mtime
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

    private func touchMemory(key: String) -> NSImage? {
        guard var entry = memoryCache[key] else { return nil }
        lruCounter += 1
        entry.lastUsed = lruCounter
        memoryCache[key] = entry
        return entry.image
    }

    private func storeInMemory(key: String, image: NSImage, imagePath: String, pixelSize: Int) {
        while memoryCache.count >= memoryLimit {
            evictLeastRecentlyUsed()
        }
        lruCounter += 1
        memoryCache[key] = MemoryEntry(image: image, lastUsed: lruCounter, pixelSize: pixelSize)
        let normalized = ThumbnailCacheKey.normalizeImagePath(imagePath)
        memoryKeysByPath[normalized, default: []].insert(key)
    }

    private func evictLeastRecentlyUsed() {
        guard let victim = memoryCache.min(by: { $0.value.lastUsed < $1.value.lastUsed }) else { return }
        memoryCache.removeValue(forKey: victim.key)
        for (path, keys) in memoryKeysByPath where keys.contains(victim.key) {
            memoryKeysByPath[path] = keys.subtracting([victim.key])
            if memoryKeysByPath[path]?.isEmpty == true {
                memoryKeysByPath.removeValue(forKey: path)
            }
        }
    }
}

// MARK: - Off-actor decode / disk I/O (Python worker threads)

private actor ThumbnailDecodePool {
    private let maxConcurrent: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    func generate(imagePath: String, size: Int, ignoreExifRotation: Bool) async -> ThumbnailCache.GeneratedThumbnail? {
        await acquire()
        defer { release() }
        return ThumbnailDecodePool.decodeThumbnail(
            imagePath: imagePath,
            size: size,
            ignoreExifRotation: ignoreExifRotation
        )
    }

    func writeJPEG(_ data: Data, to url: URL) async throws {
        await acquire()
        defer { release() }
        try data.write(to: url, options: .atomic)
    }

    private func acquire() async {
        if active < maxConcurrent {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        active += 1
    }

    private func release() {
        active -= 1
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        }
    }

    private static func decodeThumbnail(
        imagePath: String,
        size: Int,
        ignoreExifRotation: Bool
    ) -> ThumbnailCache.GeneratedThumbnail? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(
            URL(fileURLWithPath: imagePath) as CFURL,
            sourceOptions as CFDictionary
        ) else {
            return nil
        }
        let dims = originalPixelSize(from: source, ignoreExifRotation: ignoreExifRotation)
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: size,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: !ignoreExifRotation,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return ThumbnailCache.GeneratedThumbnail(
            image: cgImage,
            originalWidth: dims.width,
            originalHeight: dims.height
        )
    }

    private static func originalPixelSize(from source: CGImageSource, ignoreExifRotation: Bool) -> (width: Int, height: Int) {
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
}
