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
    /// Cached on-disk thumbnail sizes per normalized image path (avoids full cache-dir scans).
    private var diskSizesByPath: [String: Set<Int>] = [:]
    private var mtimeStatCache: [String: (mtime: Int?, cachedAt: Date)] = [:]
    private var lruCounter: UInt64 = 0
    private let memoryLimit = 12_000
    private let statCacheMaxAge: TimeInterval = 60
    private let statCacheMaxEntries = 10_000
    private struct InflightGeneration {
        let id: UInt64
        let imagePath: String
        let task: Task<GeneratedThumbnail?, Never>
        let priority: ThumbnailLoadPriority
        let queueOrder: Int
    }

    private var inflightGenerations: [String: InflightGeneration] = [:]
    private var inflightSequence: UInt64 = 0
    /// Bumped when viewport reprioritizes or background queue is cleared; stale work is dropped after acquire/decode.
    private var decodeQueueGeneration: UInt64 = 0
    /// Last background batch session accepted from the thumbnail grid (`backgroundLoadSession`).
    private var acceptedBackgroundLoadSession: UInt64 = 0
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
            diskSizesByPath.removeAll()
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
        diskSizesByPath.removeValue(forKey: normalized)
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
        registerDiskSize(imagePath: imagePath, size: size)
    }

    struct GeneratedThumbnail: Sendable {
        let image: CGImage
        /// Original pixel size after EXIF orientation, matching Python `loader_metadata`.
        /// Zero when served from the thumbnail JPEG cache (that file is not the original).
        let originalWidth: Int
        let originalHeight: Int
    }

    /// Returns `CGImage` so callers on `@MainActor` can build `NSImage` without crossing a non-Sendable boundary.
    func generateThumbnail(
        for imagePath: String,
        size: Int,
        priority: ThumbnailLoadPriority = .default
    ) async -> CGImage? {
        await generateThumbnailResult(for: imagePath, size: size, priority: priority)?.image
    }

    func generateThumbnailResult(
        for imagePath: String,
        size: Int,
        priority: ThumbnailLoadPriority = .default,
        queueOrder: Int = ThumbnailQueueOrdering.background,
        backgroundLoadSession: UInt64? = nil
    ) async -> GeneratedThumbnail? {
        let memoryKey = memoryKey(for: imagePath, size: size)
        if let cached = cachedThumbnailResult(memoryKey: memoryKey, imagePath: imagePath, size: size) {
            return cached
        }
        if let scaled = scaledDownFromLarger(imagePath: imagePath, size: size) {
            return scaled
        }

        if priority == .background, let session = backgroundLoadSession,
           session != acceptedBackgroundLoadSession {
            return nil
        }

        if let existing = inflightGenerations[memoryKey] {
            let lowerPriority = priority.rawValue < existing.priority.rawValue
            let samePriorityLaterInQueue = priority.rawValue == existing.priority.rawValue
                && queueOrder >= existing.queueOrder
            if lowerPriority || samePriorityLaterInQueue {
                return await existing.task.value
            }
            existing.task.cancel()
            inflightGenerations.removeValue(forKey: memoryKey)
        }

        let enqueuedGeneration = decodeQueueGeneration
        let ignoreExif = ignoreExifRotation
        inflightSequence += 1
        let generationID = inflightSequence
        let task = Task<GeneratedThumbnail?, Never> {
            await decodePool.generate(
                imagePath: imagePath,
                size: size,
                ignoreExifRotation: ignoreExif,
                priority: priority,
                queueOrder: queueOrder
            )
        }
        inflightGenerations[memoryKey] = InflightGeneration(
            id: generationID,
            imagePath: imagePath,
            task: task,
            priority: priority,
            queueOrder: queueOrder
        )
        let generated = await task.value
        if inflightGenerations[memoryKey]?.id == generationID {
            inflightGenerations.removeValue(forKey: memoryKey)
        }

        guard enqueuedGeneration == decodeQueueGeneration else { return nil }
        if priority == .background, let session = backgroundLoadSession,
           session != acceptedBackgroundLoadSession {
            return nil
        }
        guard let generated else { return nil }
        let image = NSImage(cgImage: generated.image, size: NSSize(width: generated.image.width, height: generated.image.height))
        try? await storeThumbnailOffDiskIO(image, for: imagePath, size: size, memoryKey: memoryKey)
        return generated
    }

    /// Drop pending decodes at or below `maxPriority` (Python `clear_queued_thumbnail_requests(max_priority:)`).
    func clearQueuedThumbnailRequests(maxPriority: ThumbnailLoadPriority) async {
        decodeQueueGeneration += 1
        let limit = maxPriority.rawValue
        for (key, entry) in inflightGenerations where entry.priority.rawValue <= limit {
            entry.task.cancel()
            inflightGenerations.removeValue(forKey: key)
        }
        await decodePool.cancelWaiters(withPriorityAtMost: limit)
    }

    /// Cancel off-viewport and stale-priority work, then callers queue viewport paths top-down.
    func reprioritizeForViewport(
        orderedVisiblePaths: [String],
        orderedNearPaths: [String]
    ) async {
        decodeQueueGeneration += 1
        let visibleSet = Set(orderedVisiblePaths)
        let nearSet = Set(orderedNearPaths)
        let keepSet = visibleSet.union(nearSet)

        for (key, entry) in inflightGenerations {
            let path = entry.imagePath
            let shouldCancel: Bool
            if visibleSet.contains(path) {
                shouldCancel = entry.priority.rawValue < ThumbnailLoadPriority.visible.rawValue
            } else if nearSet.contains(path) {
                shouldCancel = entry.priority.rawValue < ThumbnailLoadPriority.nearVisible.rawValue
            } else {
                shouldCancel = entry.priority.rawValue <= ThumbnailLoadPriority.nearVisible.rawValue
            }
            if shouldCancel {
                entry.task.cancel()
                inflightGenerations.removeValue(forKey: key)
            }
        }

        await decodePool.reprioritizeWaitersForViewport(
            visiblePaths: visibleSet,
            nearPaths: nearSet,
            keepPaths: keepSet
        )
    }

    func noteBackgroundLoadSession(_ session: UInt64) {
        acceptedBackgroundLoadSession = session
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
        registerDiskSize(imagePath: imagePath, size: size)
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
        registerDiskSize(imagePath: imagePath, size: size)
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
        let prefix = "\(base)_"
        var bestDiskSize = 0
        var bestDiskURL: URL?
        if let indexedSizes = diskSizesByPath[normalized], !indexedSizes.isEmpty {
            for cachedSize in indexedSizes where cachedSize >= size && cachedSize > bestDiskSize {
                bestDiskSize = cachedSize
                bestDiskURL = thumbnailDirectory.appendingPathComponent(
                    ThumbnailCacheKey.diskFilename(cacheKey: base, size: cachedSize)
                )
            }
        }
        if bestDiskURL == nil, memoryKeysByPath[normalized] != nil {
            guard let filenames = try? FileManager.default.contentsOfDirectory(atPath: thumbnailDirectory.path) else {
                return nil
            }
            for filename in filenames where filename.hasPrefix(prefix) && filename.hasSuffix(".jpg") {
                guard let cachedSize = parseSize(fromDiskFilename: filename, prefix: prefix) else { continue }
                registerDiskSize(imagePath: imagePath, size: cachedSize)
                if cachedSize >= size && cachedSize > bestDiskSize {
                    bestDiskSize = cachedSize
                    bestDiskURL = thumbnailDirectory.appendingPathComponent(filename)
                }
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

    private func registerDiskSize(imagePath: String, size: Int) {
        let normalized = ThumbnailCacheKey.normalizeImagePath(imagePath)
        diskSizesByPath[normalized, default: []].insert(size)
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
    private struct WaitEntry {
        let imagePath: String
        let priority: ThumbnailLoadPriority
        let queueOrder: Int
        let sequence: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private let maxConcurrent: Int
    private var active = 0
    private var activeBackgroundDecodes = 0
    private var waiters: [WaitEntry] = []
    private var waiterSequence: UInt64 = 0

    init(maxConcurrent: Int) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    func generate(
        imagePath: String,
        size: Int,
        ignoreExifRotation: Bool,
        priority: ThumbnailLoadPriority,
        queueOrder: Int
    ) async -> ThumbnailCache.GeneratedThumbnail? {
        do {
            try await acquire(imagePath: imagePath, priority: priority, queueOrder: queueOrder)
        } catch {
            return nil
        }
        defer { release(priority: priority) }
        if Task.isCancelled { return nil }
        return ThumbnailDecodePool.decodeThumbnail(
            imagePath: imagePath,
            size: size,
            ignoreExifRotation: ignoreExifRotation
        )
    }

    func cancelWaiters(withPriorityAtMost maxPriority: Int) {
        cancelWaiters { $0.priority.rawValue <= maxPriority }
    }

    func reprioritizeWaitersForViewport(
        visiblePaths: Set<String>,
        nearPaths: Set<String>,
        keepPaths: Set<String>
    ) {
        cancelWaiters { entry in
            if keepPaths.contains(entry.imagePath) {
                if visiblePaths.contains(entry.imagePath) {
                    return entry.priority.rawValue < ThumbnailLoadPriority.visible.rawValue
                }
                if nearPaths.contains(entry.imagePath) {
                    return entry.priority.rawValue < ThumbnailLoadPriority.nearVisible.rawValue
                }
            }
            return entry.priority.rawValue <= ThumbnailLoadPriority.nearVisible.rawValue
        }
    }

    private func cancelWaiters(where shouldCancel: (WaitEntry) -> Bool) {
        var kept: [WaitEntry] = []
        for entry in waiters {
            if shouldCancel(entry) {
                entry.continuation.resume(throwing: CancellationError())
            } else {
                kept.append(entry)
            }
        }
        waiters = kept
    }

    private func acquire(imagePath: String, priority: ThumbnailLoadPriority, queueOrder: Int) async throws {
        try Task.checkCancellation()
        while !canTakeDecodeSlot(priority: priority) {
            waiterSequence += 1
            let sequence = waiterSequence
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append(
                    WaitEntry(
                        imagePath: imagePath,
                        priority: priority,
                        queueOrder: queueOrder,
                        sequence: sequence,
                        continuation: continuation
                    )
                )
                sortWaiters()
            }
            try Task.checkCancellation()
        }
        active += 1
        if priority == .background {
            activeBackgroundDecodes += 1
        }
    }

    private func canTakeDecodeSlot(priority: ThumbnailLoadPriority) -> Bool {
        if active >= maxConcurrent { return false }
        if priority == .background {
            let highPriorityWaiting = waiters.contains {
                $0.priority.rawValue >= ThumbnailLoadPriority.nearVisible.rawValue
            }
            if highPriorityWaiting,
               activeBackgroundDecodes >= ThumbnailDecodeLimits.maxConcurrentBackgroundDecodes {
                return false
            }
        }
        return true
    }

    private func release(priority: ThumbnailLoadPriority) {
        active -= 1
        if priority == .background {
            activeBackgroundDecodes = max(0, activeBackgroundDecodes - 1)
        }
        guard active < maxConcurrent, !waiters.isEmpty else { return }
        sortWaiters()
        for index in waiters.indices {
            let candidate = waiters[index]
            if canTakeDecodeSlot(priority: candidate.priority) {
                let next = waiters.remove(at: index)
                active += 1
                if next.priority == .background {
                    activeBackgroundDecodes += 1
                }
                next.continuation.resume()
                return
            }
        }
    }

    private func sortWaiters() {
        waiters.sort { lhs, rhs in
            if lhs.priority.rawValue != rhs.priority.rawValue {
                return lhs.priority.rawValue > rhs.priority.rawValue
            }
            if lhs.queueOrder != rhs.queueOrder {
                return lhs.queueOrder < rhs.queueOrder
            }
            return lhs.sequence < rhs.sequence
        }
    }

    func writeJPEG(_ data: Data, to url: URL) async throws {
        try await acquire(imagePath: "", priority: .default, queueOrder: ThumbnailQueueOrdering.background)
        defer { release(priority: .default) }
        try data.write(to: url, options: .atomic)
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
        let displayImage = ThumbnailTransparencyCompositor.compositeOntoCheckerboardIfNeeded(cgImage)
        return ThumbnailCache.GeneratedThumbnail(
            image: displayImage,
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
