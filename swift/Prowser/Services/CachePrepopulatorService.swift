import AppKit
import Foundation

/// Tools > Cache Subdirectories' Thumbnails (⇧⌘C). Port of `cache/cache_prepopulator.py`.
@MainActor
enum CachePrepopulatorService {
    nonisolated private static let scanUIInterval: TimeInterval = 0.05
    private static let checkChunkSize = 100
    private static let cacheInFlightLimit = 8
    private static let cachePollInterval: Duration = .milliseconds(250)
    private static let perImageTimeout: TimeInterval = 30
    private static let stallTimeout: TimeInterval = 60

    /// Returns `true` when the user cancelled (Python `prepopulate_cache` return value).
    ///
    /// - Parameters:
    ///   - thumbnailSize: Python `MIN_THUMBNAIL_SIZE` — the size used once a folder has more than a page of thumbs.
    ///   - imagePaths: When set, skip the directory scan and only check/cache these paths
    ///     (tree "Show All Images" when the list is large). ⇧⌘C leaves this `nil`.
    ///   - directoryOverride: Root to scan (tree highlight, or active-image directory). Required when `imagePaths` is set so completion text names the right folder.
    @discardableResult
    static func prepopulateCache(
        appState: AppState,
        thumbnailSize: Int = ThumbnailGridLayoutService.minThumbnailSize,
        suppressSuccessMessages: Bool = false,
        imagePaths: [String]? = nil,
        directoryOverride: String? = nil
    ) async -> Bool {
        let currentDirectory: String? = {
            if let directoryOverride, !directoryOverride.isEmpty { return directoryOverride }
            return appState.fileData.currentImagePath.map { ($0 as NSString).deletingLastPathComponent }
        }()
        guard let currentDirectory, !currentDirectory.isEmpty,
              FileManager.default.fileExists(atPath: currentDirectory) else {
            StyledMessageDialog.showWarning(
                title: "No Directory",
                message: "No current directory available for cache prepopulation."
            )
            return false
        }

        // Python `_interrupt_thumbnail_loading`: drop queued background decodes before the heavy scan.
        let cache = appState.thumbnailCache
        await cache.clearQueuedThumbnailRequests(maxPriority: .background)

        let maxDepth = appState.config.int(forKey: "search_depth", default: 4)
        let scanLabel = imagePaths != nil
            ? "Prepopulating cache (filtered file list)..."
            : "Prepopulating cache (scanning up to \(maxDepth) levels)..."

        let panel = CancellableProgressPanelController(
            title: "Prepopulate Cache",
            labelText: scanLabel,
            maximum: 100
        )
        panel.show()

        // Phase 1: recursive scan, or caller-supplied paths.
        let imageFiles: [String]
        if let imagePaths {
            imageFiles = imagePaths
        } else {
            let excluded = PathExclusions.excludedPaths(config: appState.config)
            let includeHidden = appState.config.bool(forKey: "show_hidden_directories", default: false)
            let extensions = Set(appState.config.imageExtensions.map { DirectoryScanner.normalizeExtensionToken($0) })
            imageFiles = await Task.detached(priority: .userInitiated) {
                scanDirectoryForImages(
                    root: currentDirectory,
                    maxDepth: maxDepth,
                    excluded: excluded,
                    includeHidden: includeHidden,
                    extensions: extensions,
                    shouldCancel: { panel.cancelRequested },
                    onDirectoryScanned: { dirIndex, totalDirs, dirName, depth, imagesFound in
                        panel.setMaximum(totalDirs)
                        panel.update(
                            value: dirIndex,
                            label: "Scanning \(dirName) (depth \(depth))... (\(dirIndex + 1)/\(totalDirs))\n"
                                + "Total images found: \(imagesFound)"
                        )
                    }
                )
            }.value
        }

        if panel.cancelRequested {
            panel.close()
            return true
        }

        if imageFiles.isEmpty {
            panel.close()
            StyledMessageDialog.showWarning(
                title: "No Images",
                message: imagePaths != nil
                    ? "No image files in the filtered list to prepopulate."
                    : "No image files found in \(currentDirectory) or its subdirectories (search depth: \(maxDepth))."
            )
            return false
        }

        // Phase 2: which images still need a disk thumbnail.
        let scanProgress = imageFiles.count / 100
        panel.setMaximum(scanProgress + imageFiles.count)
        panel.update(value: scanProgress)

        let imagesToCache = await checkImagesNeedCaching(
            imageFiles,
            size: thumbnailSize,
            cache: cache,
            panel: panel,
            scanProgress: scanProgress
        )

        if panel.cancelRequested {
            panel.close()
            return true
        }

        if imagesToCache.isEmpty {
            panel.close()
            if !suppressSuccessMessages {
                StyledMessageDialog.showInformation(
                    title: "Cache Complete",
                    message: imagePaths != nil
                        ? "All \(imageFiles.count) images in the filtered list are already cached."
                        : "All \(imageFiles.count) images in the current directory and its subdirectories "
                            + "(search depth: \(maxDepth)) are already cached."
                )
            }
            return false
        }

        // Phase 3: generate the missing thumbnails.
        let checkProgress = scanProgress + imageFiles.count
        panel.setMaximum(checkProgress + imagesToCache.count)
        panel.update(value: checkProgress)

        let result = await cacheImages(
            imagesToCache,
            size: thumbnailSize,
            cache: cache,
            panel: panel,
            checkProgress: checkProgress
        )

        if result.timedOut {
            panel.close()
            let remaining = max(0, imagesToCache.count - result.cached)
            StyledMessageDialog.showWarning(
                title: "Cache Prepopulation",
                message: "Stopped after caching \(result.cached) of \(imagesToCache.count) images "
                    + "(\(remaining) remaining; workers stalled or timed out)."
            )
            return true
        }

        if result.cancelled {
            panel.close()
            StyledMessageDialog.showInformation(
                title: "Cache Prepopulation",
                message: "Cached \(result.cached) of \(imagesToCache.count) images before cancellation."
            )
            return true
        }

        panel.update(value: checkProgress + imagesToCache.count, label: "Completed: \(result.cached) images cached")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            panel.close()
        }

        if !suppressSuccessMessages {
            StyledMessageDialog.showInformation(
                title: "Cache Prepopulation Complete",
                message: imagePaths != nil
                    ? "Successfully cached \(result.cached) images from the filtered list under \(currentDirectory)."
                    : "Successfully cached \(result.cached) images from \(currentDirectory) and its subdirectories "
                        + "(search depth: \(maxDepth))."
            )
        }
        return false
    }

    // MARK: - Phase 1: scan

    /// Python `scan_directory_for_images_with_progress_recursively`: collect directories to `maxDepth`
    /// first (for a determinate bar), then list each one's image files.
    nonisolated private static func scanDirectoryForImages(
        root: String,
        maxDepth: Int,
        excluded: [String],
        includeHidden: Bool,
        extensions: Set<String>,
        shouldCancel: @Sendable () -> Bool,
        onDirectoryScanned: @Sendable (_ dirIndex: Int, _ totalDirs: Int, _ dirName: String, _ depth: Int, _ imagesFound: Int) -> Void
    ) -> [String] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var stack: [(URL, Int)] = [(URL(fileURLWithPath: root), 0)]
        var directories: [(URL, Int)] = []

        while let (dirURL, depth) = stack.popLast() {
            if DirectoryScanner.isExcludedPath(dirURL.path, excluded: excluded) { continue }
            directories.append((dirURL, depth))
            guard depth < maxDepth,
                  let entries = try? FileManager.default.contentsOfDirectory(
                      at: dirURL, includingPropertiesForKeys: Array(keys), options: []
                  ) else { continue }
            for entry in entries {
                let values = try? entry.resourceValues(forKeys: keys)
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                if !includeHidden, entry.lastPathComponent.hasPrefix(".") { continue }
                if DirectoryScanner.isExcludedPath(entry.path, excluded: excluded) { continue }
                stack.append((entry, depth + 1))
            }
        }

        let totalDirs = directories.count
        var imageFiles: [String] = []
        var lastUI = Date.distantPast

        for (dirIndex, (dirURL, depth)) in directories.enumerated() {
            if shouldCancel() { break }
            if let entries = try? FileManager.default.contentsOfDirectory(
                at: dirURL, includingPropertiesForKeys: Array(keys), options: []
            ) {
                for entry in entries {
                    let values = try? entry.resourceValues(forKeys: keys)
                    guard values?.isRegularFile == true else { continue }
                    guard extensions.contains(entry.pathExtension.lowercased()) else { continue }
                    if DirectoryScanner.isExcludedPath(entry.path, excluded: excluded) { continue }
                    imageFiles.append(entry.path)
                }
            }
            let now = Date()
            if dirIndex == totalDirs - 1 || now.timeIntervalSince(lastUI) >= scanUIInterval {
                lastUI = now
                let dirName = dirURL.lastPathComponent.isEmpty ? dirURL.path : dirURL.lastPathComponent
                onDirectoryScanned(dirIndex, totalDirs, dirName, depth, imageFiles.count)
            }
        }
        return imageFiles
    }

    // MARK: - Phase 2: check

    /// Python `check_images_need_caching_with_progress` (chunked so the panel stays responsive).
    private static func checkImagesNeedCaching(
        _ imagePaths: [String],
        size: Int,
        cache: ThumbnailCache,
        panel: CancellableProgressPanelController,
        scanProgress: Int
    ) async -> [String] {
        let total = imagePaths.count
        let diskIndex = await cache.diskThumbnailIndex()
        var imagesToCache: [String] = []
        var timing = ProgressTimingTracker()
        var start = 0
        while start < total {
            if panel.cancelRequested { break }
            let end = min(start + checkChunkSize, total)
            let needed = await cache.pathsNeedingThumbnail(
                Array(imagePaths[start..<end]), size: size, diskIndex: diskIndex
            )
            imagesToCache.append(contentsOf: needed)
            start = end
            panel.update(
                value: scanProgress + end,
                label: labelWithRemainingLine(
                    "Checking cache status... (\(end)/\(total) images)",
                    done: end, total: total, timing: &timing
                )
            )
        }
        return imagesToCache
    }

    // MARK: - Phase 3: cache

    private enum CacheEvent {
        case finished(Bool)
        case tick
    }

    /// Python `_cache_images_with_workers`: decode through the shared thumbnail pool, poll for
    /// cancel / stall, and report `done/total` with a remaining-time line.
    private static func cacheImages(
        _ imagePaths: [String],
        size: Int,
        cache: ThumbnailCache,
        panel: CancellableProgressPanelController,
        checkProgress: Int
    ) async -> (cached: Int, cancelled: Bool, timedOut: Bool) {
        let total = imagePaths.count
        var cached = 0
        var done = 0
        var cancelled = false
        var timedOut = false
        var timing = ProgressTimingTracker()
        var lastUI = Date.distantPast
        let startedAt = Date()
        var lastProgressAt = startedAt
        let maxTotalTimeout = min(1800, max(120, Double(total) * perImageTimeout))

        await withTaskGroup(of: CacheEvent.self) { group in
            var nextIndex = 0
            while nextIndex < total, nextIndex < cacheInFlightLimit {
                let path = imagePaths[nextIndex]
                nextIndex += 1
                group.addTask {
                    .finished(await cache.generateThumbnail(for: path, size: size, priority: .visible) != nil)
                }
            }
            group.addTask {
                try? await Task.sleep(for: cachePollInterval)
                return .tick
            }

            while let event = await group.next() {
                let now = Date()
                switch event {
                case .finished(let ok):
                    done += 1
                    if ok { cached += 1 }
                    lastProgressAt = now
                    if nextIndex < total {
                        let path = imagePaths[nextIndex]
                        nextIndex += 1
                        group.addTask {
                            .finished(await cache.generateThumbnail(for: path, size: size, priority: .visible) != nil)
                        }
                    }
                case .tick:
                    if done < total {
                        group.addTask {
                            try? await Task.sleep(for: cachePollInterval)
                            return .tick
                        }
                    }
                }

                if panel.cancelRequested {
                    cancelled = true
                    break
                }
                if done < total {
                    if now.timeIntervalSince(startedAt) >= maxTotalTimeout
                        || now.timeIntervalSince(lastProgressAt) >= stallTimeout {
                        timedOut = true
                        break
                    }
                }
                let milestone = done == 1 || done % 10 == 0 || done == total
                if milestone || now.timeIntervalSince(lastUI) >= 1 {
                    lastUI = now
                    panel.update(
                        value: checkProgress + done,
                        label: labelWithRemainingLine(
                            "Caching thumbnails...\n(\(done)/\(total))",
                            done: done, total: total, timing: &timing
                        )
                    )
                }
                if done == total { break }
            }
            group.cancelAll()
        }

        return (cached, cancelled, timedOut)
    }

    // MARK: - Label helpers

    /// Python `_label_with_remaining_line`: append "N images remaining (Est: …)".
    private static func labelWithRemainingLine(
        _ description: String,
        done: Int,
        total: Int,
        timing: inout ProgressTimingTracker
    ) -> String {
        let remaining = max(0, total - done)
        guard remaining > 0 else { return description }
        let estimate = done > 0 ? timing.timeEstimate(processed: done, total: total) : ""
        var line = "\(remaining) image\(remaining != 1 ? "s" : "") remaining"
        if !estimate.isEmpty {
            line += " (\(estimate))"
        }
        return description + "\n" + line
    }
}

/// Port of Python `_TimingTracker` (`search/cnn_image_similarity_sorter.py`): rolling 200-item window,
/// no estimate until 4 s elapsed or 200 items processed. Output is `"Est: m:ss"` / `"Est: h:mm:ss"`.
struct ProgressTimingTracker {
    private var startTime: Date?
    private var windowStartTime: Date?
    private var windowStartCount = 0

    init() {}

    mutating func timeEstimate(processed: Int, total: Int) -> String {
        let now = Date()
        guard let startTime, let windowStartTime else {
            self.startTime = now
            self.windowStartTime = now
            windowStartCount = 0
            return ""
        }

        var sinceWindow = processed - windowStartCount
        var windowStart = windowStartTime
        if sinceWindow >= 200 {
            self.windowStartTime = now
            windowStartCount = processed
            windowStart = now
            sinceWindow = 0
        }

        let totalElapsed = now.timeIntervalSince(startTime)
        if totalElapsed < 4, processed < 200 { return "" }

        let avgPerItem: TimeInterval
        if sinceWindow > 0, now.timeIntervalSince(windowStart) > 0 {
            avgPerItem = now.timeIntervalSince(windowStart) / Double(sinceWindow)
        } else if processed > 0 {
            avgPerItem = totalElapsed / Double(processed)
        } else {
            return ""
        }

        let remaining = total - processed
        guard remaining > 0 else { return "" }
        return Self.format(avgPerItem * Double(remaining))
    }

    private static func format(_ seconds: TimeInterval) -> String {
        guard seconds >= 0 else { return "" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "Est: %d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "Est: %d:%02d", minutes, secs)
    }
}
