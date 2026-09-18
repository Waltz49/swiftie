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
            let norm = URL(fileURLWithPath: path).standardizedFileURL.path
            guard seen.insert(norm).inserted else { return }
            paths.append(norm)
        }

        for p in includeDisplayed { add(p) }

        let extensions = Set(appState.config.imageExtensions.map { AppConfig.normalizeExtension($0) })
        let pattern = appState.filterSettings.filterPattern
        let excluded = PathExclusions.excludedPaths(config: appState.config)
        let showHidden = appState.config.bool(forKey: "show_hidden_directories", default: false)
        let maxDepth = appState.config.int(forKey: "search_depth", default: 4)

        if useCustomDirectory, let dir = customDirectory, !dir.isEmpty, FileManager.default.fileExists(atPath: dir) {
            if recursive {
                let scanned = DirectoryScanner.scanDirectoryRecursive(
                    at: dir,
                    extensions: appState.config.imageExtensions,
                    filterPattern: pattern,
                    maxDepth: maxDepth,
                    excludedPaths: excluded,
                    includeHidden: showHidden
                )
                for p in scanned { add(p) }
            } else {
                addTopLevelImages(directory: dir, extensions: extensions, pattern: pattern, add: add)
            }
            return paths
        }

        if recursive, let root = currentSearchDirectory(appState: appState) {
            let scanned = DirectoryScanner.scanDirectoryRecursive(
                at: root,
                extensions: appState.config.imageExtensions,
                filterPattern: pattern,
                maxDepth: maxDepth,
                excludedPaths: excluded,
                includeHidden: showHidden
            )
            for p in scanned { add(p) }
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
