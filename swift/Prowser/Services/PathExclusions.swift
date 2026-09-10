import Foundation

/// Path exclusion helpers. Port of `path_exclusions.py`.
@MainActor
enum PathExclusions {
    static func excludedPaths(config: AppConfig) -> [String] {
        var excluded = [
            config.prowserHome.appendingPathComponent("cache", isDirectory: true).path,
        ]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        excluded.append("\(home)/Pictures/Photos Library.photoslibrary/resources")
        excluded.append("\(home)/Pictures/Photos Library.photoslibrary/scopes")

        if let ignoreDirs = config.rawSettings()["ignore_directories"] as? [[String: Any]] {
            for entry in ignoreDirs {
                guard entry["enabled"] as? Bool == true,
                      let path = entry["path"] as? String,
                      !path.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                excluded.append((path as NSString).expandingTildeInPath)
            }
        }
        return excluded
    }

    static func isExcluded(_ path: String, excluded: [String]) -> Bool {
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
