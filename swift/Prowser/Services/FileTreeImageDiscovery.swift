import Foundation

/// Background recursive image checks for the file tree filter (`files/tree_image_discovery.py`).
@MainActor
final class FileTreeImageDiscovery {
    static let shared = FileTreeImageDiscovery()

    private var cache: [String: Bool] = [:]
    private var pending: Set<String> = []
    private var generation = 0

    func invalidate() {
        generation += 1
        cache.removeAll()
        pending.removeAll()
    }

    func cachedResult(path: String, appState: AppState) -> Bool? {
        cache[cacheKey(path: path, appState: appState)]
    }

    func scheduleCheck(path: String, appState: AppState, onUpdate: @escaping (String) -> Void) {
        let key = cacheKey(path: path, appState: appState)
        if cache[key] != nil || pending.contains(key) { return }
        pending.insert(key)

        let mode = appState.filterSettings.filteredTree
        let pattern = filterPattern(mode: mode, appState: appState)
        let maxDepth = appState.config.int(forKey: "search_depth", default: 4)
        let extensions = appState.config.imageExtensions
        let excluded = PathExclusions.excludedPaths(config: appState.config)
        let showHidden = appState.config.bool(forKey: "show_hidden_directories", default: false)
        let followSymlinks = appState.config.bool(forKey: "follow_symlinks", default: false)
        let rootPaths = Set(
            appState.config.rootDirectoriesForFileTree().map { AppConfig.standardizedRootDirectoryPath($0) }
        )
        let gen = generation

        Task.detached(priority: .utility) {
            let found = Self.directoryContainsImages(
                at: path,
                extensions: extensions,
                filterPattern: pattern,
                maxDepth: maxDepth,
                excludedPaths: excluded,
                includeHidden: showHidden,
                followSymlinks: followSymlinks,
                enabledRootPaths: rootPaths
            )
            await MainActor.run {
                guard gen == self.generation else { return }
                self.pending.remove(key)
                self.cache[key] = found
                // Only refresh the tree when a folder becomes visible (was hidden pending scan).
                if found {
                    onUpdate(path)
                }
            }
        }
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

    nonisolated static func directoryContainsImages(
        at path: String,
        extensions: [String],
        filterPattern: String,
        maxDepth: Int,
        excludedPaths: [String],
        includeHidden: Bool,
        followSymlinks: Bool,
        enabledRootPaths: Set<String>
    ) -> Bool {
        let normalizedExtensions = Set(extensions.map { normalizeExtension($0) })
        guard !normalizedExtensions.isEmpty else { return false }

        let root = URL(fileURLWithPath: path).standardizedFileURL
        var stack: [(URL, Int)] = [(root, 0)]

        while let (dirURL, depth) = stack.popLast() {
            let dirPath = dirURL.standardizedFileURL.path
            if isExcludedPath(dirPath, excluded: excludedPaths) { continue }
            if depth > maxDepth { continue }

            let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
                options: options
            ) else { continue }

            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [
                    .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                ])
                if values?.isSymbolicLink == true {
                    let linkPath = entry.standardizedFileURL.path
                    if !followSymlinks, !enabledRootPaths.contains(linkPath) { continue }
                }

                if values?.isRegularFile == true {
                    let ext = normalizeExtension(entry.pathExtension)
                    guard normalizedExtensions.contains(ext) else { continue }
                    if !DirectoryScanner.matchesGlob(entry.lastPathComponent, pattern: filterPattern) {
                        continue
                    }
                    if !isExcludedPath(entry.path, excluded: excludedPaths) {
                        return true
                    }
                    continue
                }

                guard values?.isDirectory == true else { continue }
                guard !FileTreeExcludedExtensions.shouldExcludeDirectory(named: entry.lastPathComponent) else {
                    continue
                }
                if depth < maxDepth {
                    stack.append((entry, depth + 1))
                }
            }
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
