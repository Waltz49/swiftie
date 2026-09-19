import Foundation

/// Path keys for feature caches and similarity (port of Python `realpath(abspath(expanduser(p)))`).
enum ImageRecognitionPath {
    static func normalize(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return nil }
        return URL(fileURLWithPath: expanded)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }
}
