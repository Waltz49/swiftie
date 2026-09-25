import Foundation

@MainActor
enum SearchImagePathCollector {
    static func currentSearchDirectory(appState: AppState) -> String? {
        if let directory = appState.fileData.currentDirectory {
            return directory
        }
        if let first = appState.fileData.displayedImages.first {
            return (first as NSString).deletingLastPathComponent
        }
        return nil
    }

    static func collectPaths(
        appState: AppState,
        recursive: Bool,
        customDirectory: String?,
        useCustomDirectory: Bool,
        includeDisplayed: [String]
    ) -> [String] {
        var paths: [String] = []
        var seen = Set<String>()

        func add(_ path: String) {
            let norm = ImageRecognitionPath.normalize(path)
                ?? URL(fileURLWithPath: path).standardizedFileURL.path
            guard seen.insert(norm).inserted else { return }
            paths.append(norm)
        }

        func matchesActiveFilter(_ path: String, pattern: String) -> Bool {
            let name = (path as NSString).lastPathComponent
            return DirectoryScanner.matchesGlob(name, pattern: pattern)
        }

        for p in includeDisplayed { add(p) }

        let extensions = appState.config.imageExtensions
        let pattern = appState.filterSettings.filterPattern
        let excluded = PathExclusions.excludedPaths(config: appState.config)
        let showHidden = appState.config.bool(forKey: "show_hidden_directories", default: false)
        let maxDepth = appState.config.int(forKey: "search_depth", default: 4)

        if useCustomDirectory, let dir = customDirectory, !dir.isEmpty {
            let expanded = AppState.expandedSearchDirectoryPath(dir)
            guard FileManager.default.fileExists(atPath: expanded) else { return paths }
            if recursive {
                let scanned = DirectoryScanner.scanDirectoryRecursive(
                    at: expanded,
                    extensions: extensions,
                    filterPattern: pattern,
                    maxDepth: maxDepth,
                    excludedPaths: excluded,
                    includeHidden: showHidden
                )
                for p in scanned { add(p) }
            } else {
                let extSet = Set(extensions.map { AppConfig.normalizeExtension($0) })
                addTopLevelImages(directory: expanded, extensions: extSet, pattern: pattern, add: add)
            }
            return paths
        }

        if recursive {
            // Python: when not using a custom search dir, seed with current displayed images (filtered).
            if !useCustomDirectory {
                for p in appState.fileData.displayedImages where matchesActiveFilter(p, pattern: pattern) {
                    add(p)
                }
            }
            if let root = currentSearchDirectory(appState: appState) {
                let scanned = DirectoryScanner.scanDirectoryRecursive(
                    at: root,
                    extensions: extensions,
                    filterPattern: pattern,
                    maxDepth: maxDepth,
                    excludedPaths: excluded,
                    includeHidden: showHidden
                )
                for p in scanned { add(p) }
            }
            return paths
        }

        if !useCustomDirectory {
            for p in appState.fileData.displayedImages {
                add(p)
            }
        }
        return paths
    }

    private static func addTopLevelImages(
        directory: String,
        extensions: Set<String>,
        pattern: String,
        add: (String) -> Void
    ) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for name in files {
            let path = (directory as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let ext = (name as NSString).pathExtension.lowercased()
            guard extensions.contains(ext) else { continue }
            if pattern != "*" && !pattern.isEmpty {
                guard DirectoryScanner.matchesGlob(name, pattern: pattern) else { continue }
            }
            add(path)
        }
    }
}
