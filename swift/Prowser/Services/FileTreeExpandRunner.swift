import Foundation

/// Background path discovery for ⌘↩ tree expand (`files/file_tree_handler.py` `expand_file_tree`).
enum FileTreeExpandRunner {
    struct ScanContext: Sendable {
        let startDir: String
        let walkMaxDepth: Int
        let mode: String
        let filterPattern: String
        let imageExtensions: [String]
        let excludedPaths: [String]
        let includeHidden: Bool
        let followSymlinks: Bool
        let enabledRootPaths: Set<String>
    }

    /// Parent directories to expand (shallowest first), excluding `startDir` itself.
    nonisolated static func discoverPathsToExpand(context: ScanContext) -> [String] {
        let startDir = URL(fileURLWithPath: context.startDir).standardizedFileURL.path
        var directoriesWithImages = Set<String>()
        var stack: [(URL, Int)] = [(URL(fileURLWithPath: startDir), 0)]
        let normalizedExtensions = Set(context.imageExtensions.map { DirectoryScanner.normalizeExtensionToken($0) })
        guard !normalizedExtensions.isEmpty else { return [] }

        let matchPattern: String = {
            if context.mode == "use_filter" {
                return DirectoryScanner.patternForMatching(context.filterPattern)
            }
            return "*"
        }()

        while let (dirURL, depth) = stack.popLast() {
            let dirPath = dirURL.standardizedFileURL.path
            if DirectoryScanner.isExcludedPath(dirPath, excluded: context.excludedPaths) { continue }
            if shouldSkipDirectoryPath(dirPath) { continue }
            if depth > context.walkMaxDepth { continue }

            let options: FileManager.DirectoryEnumerationOptions = context.includeHidden ? [] : [.skipsHiddenFiles]
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
                options: options
            ) else { continue }

            var subdirs: [URL] = []
            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [
                    .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                ])
                if values?.isSymbolicLink == true {
                    let linkPath = entry.standardizedFileURL.path
                    if !context.followSymlinks, !context.enabledRootPaths.contains(linkPath) { continue }
                }
                if values?.isRegularFile == true {
                    let ext = DirectoryScanner.normalizeExtensionToken(entry.pathExtension)
                    guard normalizedExtensions.contains(ext) else { continue }
                    if context.mode == "use_filter", matchPattern != "*" {
                        if !DirectoryScanner.matchesGlob(entry.lastPathComponent, pattern: matchPattern) { continue }
                    }
                    if !DirectoryScanner.isExcludedPath(entry.path, excluded: context.excludedPaths) {
                        directoriesWithImages.insert(dirPath)
                        break
                    }
                } else if values?.isDirectory == true {
                    guard !FileTreeExcludedExtensions.shouldExcludeDirectory(named: entry.lastPathComponent) else {
                        continue
                    }
                    subdirs.append(entry)
                }
            }

            if depth < context.walkMaxDepth {
                for entry in subdirs {
                    stack.append((entry, depth + 1))
                }
            }
        }

        var unique = Set<String>()
        for dirPath in directoriesWithImages {
            var current = dirPath
            while current != startDir {
                unique.insert(current)
                let parent = URL(fileURLWithPath: current).deletingLastPathComponent().standardizedFileURL.path
                if parent == current { break }
                current = parent
            }
        }
        return unique.sorted { pathDepthKey($0) < pathDepthKey($1) }
    }

    nonisolated private static func pathDepthKey(_ path: String) -> Int {
        path.filter { $0 == "/" }.count + path.split(separator: "/").count
    }

    nonisolated private static func shouldSkipDirectoryPath(_ path: String) -> Bool {
        for pattern in FileTreeSkippedPathPatterns.patterns {
            if path.contains(pattern) { return true }
        }
        return false
    }
}
