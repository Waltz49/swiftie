import Foundation

/// Recursive image file collection with cancellable progress (port of Python `os.walk` scan phases in duplicate/similar search).
enum RecursiveImageScanRunner {
    struct ScanResult: Sendable {
        var paths: [String]
        var cancelled: Bool
    }

    static func scanImages(
        at rootPath: String,
        extensions: [String],
        excludedPaths: [String],
        includeHidden: Bool,
        filterPattern: String = "*",
        shouldCancel: @escaping @Sendable () -> Bool,
        onDirectoryVisited: @escaping @Sendable (String, Int) -> Void
    ) -> ScanResult {
        let normalizedExtensions = Set(extensions.map { DirectoryScanner.normalizeExtensionToken($0) })
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: root.path) else {
            return ScanResult(paths: [], cancelled: false)
        }

        var results: [String] = []
        var fileCount = 0
        var stack: [URL] = [root]

        while let dirURL = stack.popLast() {
            if shouldCancel() {
                return ScanResult(paths: results, cancelled: true)
            }

            let dirPath = dirURL.standardizedFileURL.path
            if DirectoryScanner.isExcludedPath(dirPath, excluded: excludedPaths) { continue }

            let relPath = relativePath(from: root.path, to: dirPath)
            onDirectoryVisited(relPath, fileCount)

            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: includeHidden ? [] : [.skipsHiddenFiles]
            ) else { continue }

            var subdirs: [URL] = []
            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                if values?.isDirectory == true {
                    if !includeHidden, entry.lastPathComponent.hasPrefix(".") { continue }
                    subdirs.append(entry)
                    continue
                }
                guard values?.isRegularFile == true else { continue }
                let ext = entry.pathExtension.lowercased()
                guard normalizedExtensions.contains(ext) else { continue }
                if !DirectoryScanner.matchesGlob(entry.lastPathComponent, pattern: filterPattern) { continue }
                let filePath = entry.standardizedFileURL.path
                if DirectoryScanner.isExcludedPath(filePath, excluded: excludedPaths) { continue }
                results.append(filePath)
                fileCount += 1
            }
            for sub in subdirs.reversed() {
                stack.append(sub)
            }
        }

        return ScanResult(paths: results, cancelled: false)
    }

    private static func relativePath(from root: String, to path: String) -> String {
        let rootNorm = URL(fileURLWithPath: root).standardizedFileURL.path
        let pathNorm = URL(fileURLWithPath: path).standardizedFileURL.path
        if pathNorm == rootNorm { return "." }
        let prefix = rootNorm + "/"
        if pathNorm.hasPrefix(prefix) {
            return String(pathNorm.dropFirst(prefix.count))
        }
        return pathNorm
    }
}
