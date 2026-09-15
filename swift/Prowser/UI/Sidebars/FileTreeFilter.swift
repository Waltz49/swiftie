import Foundation

/// Bundle/system package extensions hidden from the tree (`thumbnails/thumbnail_constants.py` `EXCLUDED_EXTENSIONS`).
enum FileTreeExcludedExtensions {
    private static let extensions: Set<String> = [
        ".app", ".pxd", ".framework", ".bundle", ".plugin", ".component",
        ".pkg", ".egg", ".pages", ".whl", ".ipa", ".apk", ".deb", ".rpm",
    ]

    static func shouldExcludeDirectory(named name: String) -> Bool {
        let lower = name.lowercased()
        return extensions.contains { lower.hasSuffix($0) }
    }
}

/// Directory visibility for the file tree (port of `CustomFileSystemFilter`).
@MainActor
enum FileTreeFilter {
    private static var cache: [String: Bool] = [:]
    private static var cacheKey = ""
    private static var onUpdateHandler: ((Set<String>) -> Void)?
    private static var debounceTask: Task<Void, Never>?
    private static var pendingDiscoveryPaths: Set<String> = []

    static func setUpdateHandler(_ handler: @escaping (Set<String>) -> Void) {
        onUpdateHandler = handler
    }

    /// Directories that must stay visible while navigating (Python `priority_paths`).
    private static var priorityPaths: Set<String> = []

    /// Drop shallow visibility cache only (keep background discovery results).
    static func clearShallowCache() {
        cache.removeAll()
    }

    static func invalidateCache() {
        clearShallowCache()
        cacheKey = ""
        priorityPaths.removeAll()
        debounceTask?.cancel()
        debounceTask = nil
        FileTreeImageDiscovery.shared.invalidate()
    }

    static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// True when thumbnails can list files from more than one folder (`highlight_current_file` exception).
    private static func followsActiveImageDirectoryInTree(appState: AppState) -> Bool {
        appState.specificFilesActive || appState.referenceGraphActive
    }

    /// Directory the tree should track for navigation/filter paths.
    /// Prefer `currentDirectory` (set synchronously in `load_directory`) over the image path,
    /// which can lag during async thumbnail loads (Python `highlight_current_directory`).
    static func highlightDirectory(appState: AppState) -> String? {
        if followsActiveImageDirectoryInTree(appState: appState),
           let path = appState.fileData.currentImagePath {
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
            if !dir.isEmpty { return standardizedPath(dir) }
        }
        if let current = appState.fileData.currentDirectory {
            return standardizedPath(current)
        }
        if let path = appState.fileData.currentImagePath {
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
            if !dir.isEmpty { return standardizedPath(dir) }
        }
        return nil
    }

    /// Directory row for tree expand/select while following the active image (Python `highlight_current_file`).
    static func directoryForTreeImageHighlight(appState: AppState) -> String? {
        if followsActiveImageDirectoryInTree(appState: appState),
           let path = appState.fileData.currentImagePath {
            let imageDir = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
            if !imageDir.isEmpty { return standardizedPath(imageDir) }
        }
        if let path = appState.fileData.currentImagePath {
            let imageDir = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
            if !imageDir.isEmpty {
                let normalizedImageDir = standardizedPath(imageDir)
                if let current = appState.fileData.currentDirectory {
                    let normalizedCurrent = standardizedPath(current)
                    if normalizedImageDir != normalizedCurrent {
                        return normalizedCurrent
                    }
                }
                return normalizedImageDir
            }
        }
        return highlightDirectory(appState: appState)
    }

    /// Keep a directory and its ancestors visible in filtered tree modes.
    static func addPriorityPath(_ path: String) {
        var current = standardizedPath(path)
        while true {
            priorityPaths.insert(current)
            let parent = URL(fileURLWithPath: current).deletingLastPathComponent().standardizedFileURL.path
            if parent == current { break }
            current = parent
        }
    }

    static func scheduleDebouncedUpdate(discoveredPath: String) {
        pendingDiscoveryPaths.insert(discoveredPath)
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            let paths = pendingDiscoveryPaths
            pendingDiscoveryPaths.removeAll()
            guard !paths.isEmpty else { return }
            onUpdateHandler?(paths)
        }
    }

    /// Immediate child directories on disk (same exclusions as `FileTreeNode` loading).
    static func immediateChildDirectoryPaths(at path: String, appState: AppState) -> [String] {
        let showHidden = appState.config.bool(forKey: "show_hidden_directories", default: false)
        let excluded = PathExclusions.excludedPaths(config: appState.config)
        let url = URL(fileURLWithPath: path)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: showHidden ? [] : [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries
            .filter { !PathExclusions.isExcluded($0.path, excluded: excluded) }
            .compactMap { entry -> String? in
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                guard isDir else { return nil }
                guard !FileTreeExcludedExtensions.shouldExcludeDirectory(named: entry.lastPathComponent) else {
                    return nil
                }
                return entry.standardizedFileURL.path
            }
    }

    /// Whether this directory has matching images (shallow + deep discovery). Ignores navigation/priority visibility.
    static func directoryContainsImagesForFilter(at path: String, appState: AppState) -> Bool {
        let mode = appState.filterSettings.filteredTree
        if mode == "all" { return true }
        let pattern = mode == "use_filter" ? appState.filterSettings.filterPattern : "*"
        return directoryContainsImagesForFilter(
            at: path,
            mode: mode,
            pattern: pattern,
            appState: appState
        )
    }

    private static func directoryContainsImagesForFilter(
        at path: String,
        mode: String,
        pattern: String,
        appState: AppState
    ) -> Bool {
        let extensions = appState.config.imageExtensions
        let immediate = DirectoryScanner.scanDirectory(
            at: path,
            extensions: extensions,
            filterPattern: pattern
        )
        if !immediate.isEmpty { return true }
        if let cached = FileTreeImageDiscovery.shared.cachedResult(path: path, appState: appState) {
            return cached
        }
        FileTreeImageDiscovery.shared.scheduleCheck(path: path, appState: appState) { discoveredPath in
            clearShallowCache()
            scheduleDebouncedUpdate(discoveredPath: discoveredPath)
        }
        return false
    }

    /// True when an immediate subdirectory contains matching images (used for expand/collapse disclosure).
    static func hasFilteredChildDirectory(at path: String, appState: AppState) -> Bool {
        let mode = appState.filterSettings.filteredTree
        if mode == "all" { return false }
        let pattern = mode == "use_filter" ? appState.filterSettings.filterPattern : "*"
        for childPath in immediateChildDirectoryPaths(at: path, appState: appState) {
            if directoryContainsImagesForFilter(
                at: childPath,
                mode: mode,
                pattern: pattern,
                appState: appState
            ) {
                return true
            }
        }
        return false
    }

    static func shouldShowDirectory(at path: String, appState: AppState, rootPaths: [String]) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let normalizedRoots = rootPaths.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path
        }
        if normalizedRoots.contains(normalized) {
            return true
        }

        let mode = appState.filterSettings.filteredTree
        if mode == "all" { return true }

        // Keep ancestors of the highlighted image directory visible (Python priority_paths).
        if isOnNavigationPath(normalized, appState: appState) {
            return true
        }

        let pattern = mode == "use_filter" ? appState.filterSettings.filterPattern : "*"
        let key = "\(mode)|\(pattern)"
        if key != cacheKey {
            cache.removeAll()
            cacheKey = key
        }
        if let cached = cache[normalized] {
            return cached
        }

        let result = directoryContainsImagesForFilter(
            at: normalized,
            mode: mode,
            pattern: pattern,
            appState: appState
        )
        cache[normalized] = result
        return result
    }

    private static func isOnNavigationPath(_ path: String, appState: AppState) -> Bool {
        let pathNorm = standardizedPath(path)
        if priorityPaths.contains(pathNorm) {
            return true
        }
        for directory in navigationDirectories(appState: appState) {
            if directory == pathNorm || directory.hasPrefix(pathNorm + "/") {
                return true
            }
        }
        return false
    }

    private static func navigationDirectories(appState: AppState) -> [String] {
        var directories: [String] = []
        if let highlight = highlightDirectory(appState: appState) {
            directories.append(highlight)
        }
        if let current = appState.fileData.currentDirectory {
            let normalized = standardizedPath(current)
            if !directories.contains(normalized) {
                directories.append(normalized)
            }
        }
        return directories
    }
}
