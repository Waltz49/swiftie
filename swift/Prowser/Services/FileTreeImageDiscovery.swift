import Foundation

/// Background recursive image checks for the file tree filter (`files/tree_image_discovery.py`).
@MainActor
final class FileTreeImageDiscovery {
    static let shared = FileTreeImageDiscovery()

    private var cache: [String: Bool] = [:]
    private var generation = 0

    private struct QueuedCheck {
        let priority: Int
        let sequence: Int
        let path: String
        let cacheKey: String
        let context: CheckContext
        let generation: Int
    }

    private struct CheckContext: Sendable {
        let mode: String
        let filterPattern: String
        let maxDepth: Int
        let extensions: [String]
        let excludedPaths: [String]
        let includeHidden: Bool
        let followSymlinks: Bool
        let enabledRootPaths: Set<String>
    }

    private var queue: [QueuedCheck] = []
    private var queuedPriorityByKey: [String: Int] = [:]
    /// Paths currently walking on a detached task (same `generation` as when started).
    private var inFlightGenerationByKey: [String: Int] = [:]
    private var sequence = 0
    private var workerRunning = false

    func invalidate() {
        generation += 1
        cache.removeAll()
        queue.removeAll()
        queuedPriorityByKey.removeAll()
        // Leave `workerRunning` set so an in-flight walk stays the only worker.
        // It drops its result on the generation check, then drains anything queued since.
    }

    func cachedResult(path: String, appState: AppState) -> Bool? {
        cache[cacheKey(path: path, appState: appState)]
    }

    func scheduleCheck(
        path: String,
        appState: AppState,
        priority: Int = 2,
        onUpdate: @escaping (String, Bool) -> Void
    ) {
        let key = cacheKey(path: path, appState: appState)
        if cache[key] != nil { return }
        let gen = generation
        if inFlightGenerationByKey[key] == gen { return }
        if let existing = queuedPriorityByKey[key] {
            if priority >= existing { return }
            queue.removeAll { $0.cacheKey == key }
        }

        let context = makeContext(appState: appState)
        sequence += 1
        let item = QueuedCheck(
            priority: priority,
            sequence: sequence,
            path: path,
            cacheKey: key,
            context: context,
            generation: gen
        )
        queuedPriorityByKey[key] = priority
        queue.append(item)
        pumpWorker(onUpdate: onUpdate)
    }

    private func pumpWorker(onUpdate: @escaping (String, Bool) -> Void) {
        guard !workerRunning else { return }
        queue.sort { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return lhs.sequence < rhs.sequence
        }
        while !queue.isEmpty {
            let next = queue.removeFirst()
            // A later enqueue of the same path replaced this one (Python heap stale-priority skip).
            guard queuedPriorityByKey[next.cacheKey] == next.priority else { continue }
            queuedPriorityByKey.removeValue(forKey: next.cacheKey)
            workerRunning = true

            let path = next.path
            let cacheKey = next.cacheKey
            let context = next.context
            let gen = next.generation
            inFlightGenerationByKey[cacheKey] = gen

            Task.detached(priority: .utility) {
                let found = Self.directoryContainsImages(at: path, context: context)
                await MainActor.run {
                    self.workerRunning = false
                    self.inFlightGenerationByKey.removeValue(forKey: cacheKey)
                    if gen == self.generation, self.cache[cacheKey] == nil {
                        self.cache[cacheKey] = found
                        onUpdate(path, found)
                    }
                    self.pumpWorker(onUpdate: onUpdate)
                }
            }
            return
        }
    }

    private func makeContext(appState: AppState) -> CheckContext {
        let mode = appState.filterSettings.filteredTree
        let pattern = filterPattern(mode: mode, appState: appState)
        let maxDepth = appState.config.int(forKey: "search_depth", default: 4)
        let extensions = appState.config.imageExtensions
        return CheckContext(
            mode: mode,
            filterPattern: pattern,
            maxDepth: maxDepth,
            extensions: extensions,
            excludedPaths: PathExclusions.excludedPaths(config: appState.config),
            includeHidden: appState.config.bool(forKey: "show_hidden_directories", default: false),
            followSymlinks: appState.config.bool(forKey: "follow_symlinks", default: false),
            enabledRootPaths: Set(
                appState.config.rootDirectoriesForFileTree().map { AppConfig.standardizedRootDirectoryPath($0) }
            )
        )
    }

    private func cacheKey(path: String, appState: AppState) -> String {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let mode = appState.filterSettings.filteredTree
        let pattern = filterPattern(mode: mode, appState: appState)
        let depth = appState.config.int(forKey: "search_depth", default: 4)
        return "\(normalized)|\(depth)|\(mode)|\(pattern)"
    }

    private func filterPattern(mode: String, appState: AppState) -> String {
        mode == "use_filter" ? appState.filterSettings.filterPattern : "*"
    }

    nonisolated private static func directoryContainsImages(at path: String, context: CheckContext) -> Bool {
        if context.mode == "all" { return true }
        let normalizedExtensions = Set(context.extensions.map { normalizeExtension($0) })
        guard !normalizedExtensions.isEmpty else { return false }

        let matchPattern = context.mode == "use_filter"
            ? DirectoryScanner.patternForMatching(context.filterPattern)
            : "*"

        let root = URL(fileURLWithPath: path).standardizedFileURL
        var stack: [(URL, Int)] = [(root, 0)]

        while let (dirURL, depth) = stack.popLast() {
            let dirPath = dirURL.standardizedFileURL.path
            if isExcludedPath(dirPath, excluded: context.excludedPaths) { continue }
            if depth > context.maxDepth { continue }
            if shouldSkipDirectoryPath(dirPath) { continue }

            let options: FileManager.DirectoryEnumerationOptions = context.includeHidden ? [] : [.skipsHiddenFiles]
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
                options: options
            ) else { continue }

            var subdirs: [URL] = []
            var regularFiles: [URL] = []
            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [
                    .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                ])
                if values?.isSymbolicLink == true {
                    let linkPath = entry.standardizedFileURL.path
                    if !context.followSymlinks, !context.enabledRootPaths.contains(linkPath) { continue }
                }
                if values?.isRegularFile == true {
                    regularFiles.append(entry)
                } else if values?.isDirectory == true {
                    guard !FileTreeExcludedExtensions.shouldExcludeDirectory(named: entry.lastPathComponent) else {
                        continue
                    }
                    subdirs.append(entry)
                }
            }

            for entry in regularFiles {
                let ext = normalizeExtension(entry.pathExtension)
                guard normalizedExtensions.contains(ext) else { continue }
                if context.mode == "use_filter", matchPattern != "*" {
                    if !DirectoryScanner.matchesGlob(entry.lastPathComponent, pattern: matchPattern) { continue }
                }
                if !isExcludedPath(entry.path, excluded: context.excludedPaths) {
                    return true
                }
            }

            if depth < context.maxDepth {
                for entry in subdirs {
                    stack.append((entry, depth + 1))
                }
            }
        }
        return false
    }

    /// Port of `SKIPPED_PATTERNS` substring checks in `deep_check_has_images`.
    nonisolated private static func shouldSkipDirectoryPath(_ path: String) -> Bool {
        for pattern in FileTreeSkippedPathPatterns.patterns {
            if path.contains(pattern) { return true }
        }
        return false
    }

    nonisolated private static func normalizeExtension(_ ext: String) -> String {
        let lower = ext.lowercased()
        if lower.hasPrefix(".") { return String(lower.dropFirst()) }
        return lower
    }

    nonisolated private static func isExcludedPath(_ path: String, excluded: [String]) -> Bool {
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.path
        for excl in excluded {
            let exclResolved = URL(fileURLWithPath: excl).standardizedFileURL.path
            if resolved == exclResolved || resolved.hasPrefix(exclResolved + "/") {
                return true
            }
        }
        return false
    }
}

/// Substrings that skip deep tree walks (`thumbnails/thumbnail_constants.py` `SKIPPED_PATTERNS`).
enum FileTreeSkippedPathPatterns {
    static let patterns: [String] = [".app", ".framework", ".bundle", ".pkg", ".pages"]
}

