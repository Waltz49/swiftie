import Foundation

/// Port of `imagegen_plugins/image_gen_naming.py` (path allocation only).
@MainActor
enum ImageGenPathNaming {
    private static let filePattern = try? NSRegularExpression(
        pattern: #"imagegen-(\d{4})\.[^.]+$"#,
        options: [.caseInsensitive]
    )

    static func imageCreationDirectory(config: AppConfig) -> String {
        let (path, enabled) = config.imageCreationDirectory()
        if enabled, let path, !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                return expanded
            }
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent("Downloads")
    }

    static func defaultImageCreationDirectory() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Downloads")
    }

    static func nextImageGenPath(config: AppConfig, ext: String = ".png") -> String {
        let directory = imageCreationDirectory(config: config)
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let nextIndex = highestImageGenIndex(in: directory) + 1
        let normalizedExt = ext.hasPrefix(".") ? ext : ".\(ext)"
        return "\(directory)/imagegen-\(String(format: "%04d", nextIndex))\(normalizedExt)"
    }

    private static func highestImageGenIndex(in directory: String) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return 0 }
        var highest = 0
        for name in names {
            guard let match = filePattern?.firstMatch(
                in: name,
                range: NSRange(name.startIndex..., in: name)
            ), match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: name),
                  let value = Int(name[range]) else { continue }
            highest = max(highest, value)
        }
        return highest
    }
}
