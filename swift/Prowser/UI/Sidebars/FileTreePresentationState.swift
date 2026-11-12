import Foundation

/// Session expansion path helpers (testable; single source of truth is `AppState.fileTreeExpandedDirectoryPaths`).
enum FileTreePresentationState {
    static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Drop expansion entries whose directories no longer exist on disk.
    static func pruneMissingExpandedPaths(_ paths: Set<String>) -> Set<String> {
        paths.filter { path in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                return false
            }
            return true
        }
    }

    /// Paths removed when the user collapses `collapsedPath` (that path and descendants).
    static func expandedPaths(afterCollapsing collapsedPath: String, in expanded: Set<String>) -> Set<String> {
        let prefix = collapsedPath + "/"
        return expanded.filter { path in
            path != collapsedPath && !path.hasPrefix(prefix)
        }
    }
}
