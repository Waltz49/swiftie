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

    /// Directory the tree should highlight: parent of the current image, else `currentDirectory`.
    /// Matches Python `highlight_current_file` using `os.path.dirname(current_image_path)`.
    static func highlightDirectory(appState: AppState) -> String? {
        if let path = appState.fileData.currentImagePath {
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
            if !dir.isEmpty { return dir }
        }
        guard let current = appState.fileData.currentDirectory else { return nil }
        return standardizedPath(current)
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

        let result = evaluateDirectory(at: normalized, mode: mode, pattern: pattern, appState: appState)
        cache[normalized] = result
        return result
    }

    private static func evaluateDirectory(
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
