import Darwin
import Foundation

/// Scans a directory for image files. Port of `directory_loader._scan_directory_efficiently`.
enum DirectoryScanner {
    static func scanDirectory(
        at path: String,
        extensions: [String],
        filterPattern: String = "*"
    ) -> [String] {
        let normalizedExtensions = Set(extensions.map { normalizeExtensionToken($0) })
        let url = URL(fileURLWithPath: path)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [String] = []
        for fileURL in entries {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            let ext = fileURL.pathExtension.lowercased()
            guard normalizedExtensions.contains(ext) else { continue }
            if !matchesGlob(fileURL.lastPathComponent, pattern: filterPattern) { continue }
            results.append(fileURL.standardizedFileURL.path)
        }
        return results.sorted()
    }

    static func scanDirectoryRecursive(
        at path: String,
        extensions: [String],
        filterPattern: String = "*",
        maxDepth: Int? = nil,
        excludedPaths: [String] = [],
        includeHidden: Bool = false
    ) -> [String] {
        let normalizedExtensions = Set(extensions.map { normalizeExtensionToken($0) })
        let root = URL(fileURLWithPath: path).standardizedFileURL
        var results: [String] = []
        var stack: [(URL, Int)] = [(root, 0)]

        while let (dirURL, depth) = stack.popLast() {
            let dirPath = dirURL.standardizedFileURL.path
            if isExcludedPath(dirPath, excluded: excludedPaths) { continue }
            if maxDepth != nil, depth > maxDepth! { continue }

            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: includeHidden ? [] : [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                if values?.isDirectory == true {
                    if maxDepth == nil || depth < maxDepth! {
                        stack.append((entry, depth + 1))
                    }
                    continue
                }
                guard values?.isRegularFile == true else { continue }
                let ext = entry.pathExtension.lowercased()
                guard normalizedExtensions.contains(ext) else { continue }
                if !matchesGlob(entry.lastPathComponent, pattern: filterPattern) { continue }
                let filePath = entry.standardizedFileURL.path
                if isExcludedPath(filePath, excluded: excludedPaths) { continue }
                results.append(filePath)
            }
        }

        return results.sorted()
    }

    static func isExcludedPath(_ path: String, excluded: [String]) -> Bool {
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.path
        for excl in excluded {
            let exclResolved = URL(fileURLWithPath: excl).standardizedFileURL.path
            if resolved == exclResolved || resolved.hasPrefix(exclResolved + "/") {
                return true
            }
        }
        return false
    }

    /// Filename filter match (Python `sorting_manager.filter_images_by_pattern`).
    static func matchesGlob(_ filename: String, pattern: String) -> Bool {
        if pattern == "*" || pattern.isEmpty { return true }
        let matchPattern = patternForMatching(pattern)
        return filename.withCString { namePtr in
            matchPattern.withCString { patternPtr in
                fnmatch(patternPtr, namePtr, FNM_CASEFOLD) == 0
            }
        }
    }

    /// Port of `ImageBrowserConfig.get_filter_pattern_for_matching` + `fnmatch.fnmatch(..., .lower())`.
    static func patternForMatching(_ storedPattern: String) -> String {
        if storedPattern == "*" || storedPattern.isEmpty { return "*" }
        if storedPattern.contains("*") || storedPattern.contains("?") || storedPattern.contains("[") {
            return storedPattern
        }
        return storedPattern + "*"
    }

    static func normalizeExtensionToken(_ ext: String) -> String {
        let lower = ext.lowercased()
        if lower.hasPrefix(".") { return String(lower.dropFirst()) }
        return lower
    }
}
