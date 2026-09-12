import Foundation

/// Port of `browser_window/managers/rename_status_manager.py`.
@Observable
@MainActor
final class RenameStatusManager {
    private let statusFileURL: URL
    private var statusCache: [String: Bool] = [:]
    private(set) var isEnabled = false

    init(dataDirectory: URL) {
        statusFileURL = dataDirectory.appendingPathComponent("rename_status.json")
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled {
            statusCache.removeAll()
            try? FileManager.default.removeItem(at: statusFileURL)
        }
    }

    func toggle() {
        setEnabled(!isEnabled)
    }

    func directoryStatus(_ directory: String) -> Bool? {
        guard isEnabled else { return nil }
        let key = Self.normalizePath(directory)
        return statusCache[key]
    }

    func scanVisibleDirectories(_ directories: [String], config: AppConfig) {
        guard isEnabled else { return }
        let template = config.string(forKey: "rename_prefix_template", default: "image-%d")
        let incrementLength = config.int(forKey: "rename_increment_length", default: 4)
        let filterPattern = config.string(forKey: "filter_pattern", default: "*")
        let extensions = config.imageExtensions

        for directory in directories {
            let key = Self.normalizePath(directory)
            statusCache[key] = Self.checkDirectoryStatus(
                directory: directory,
                renamePrefixTemplate: template,
                incrementLength: incrementLength,
                filterPattern: filterPattern,
                extensions: extensions
            )
        }
        persistCache()
    }

    private func persistCache() {
        guard let data = try? JSONSerialization.data(withJSONObject: statusCache) else { return }
        try? data.write(to: statusFileURL)
    }

    private static func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func checkDirectoryStatus(
        directory: String,
        renamePrefixTemplate: String,
        incrementLength: Int,
        filterPattern: String,
        extensions: [String]
    ) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue else {
            return false
        }

        let dirname = (directory as NSString).lastPathComponent
        let prefix: String
        if renamePrefixTemplate.contains("%d") || renamePrefixTemplate.contains("%D") {
            prefix = renamePrefixTemplate
                .replacingOccurrences(of: "%d", with: dirname)
                .replacingOccurrences(of: "%D", with: dirname)
        } else {
            prefix = renamePrefixTemplate.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }

        let extSet = Set(
            extensions.map {
                let e = $0.lowercased()
                return e.hasPrefix(".") ? e : ".\(e)"
            }
        )

        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return false
        }
        var imageFiles = files.filter { name in
            let path = (directory as NSString).appendingPathComponent(name)
            var isFileDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isFileDir), !isFileDir.boolValue else {
                return false
            }
            return extSet.contains((name as NSString).pathExtension.lowercased())
        }
        guard !imageFiles.isEmpty else { return false }

        if !filterPattern.isEmpty, filterPattern != "*" {
            imageFiles = imageFiles.filter { fnmatch($0, pattern: filterPattern) }
        }
        guard !imageFiles.isEmpty else { return false }

        var numbers: [Int] = []
        for filename in imageFiles {
            guard let number = extractNumber(from: filename, prefix: prefix, incrementLength: incrementLength) else {
                return false
            }
            numbers.append(number)
        }
        numbers.sort()
        let minNumber = numbers[0]
        let expected = Set(minNumber..<(minNumber + numbers.count))
        return expected == Set(numbers)
    }

    private static func extractNumber(
        from filename: String,
        prefix: String,
        incrementLength: Int
    ) -> Int? {
        let base = (filename as NSString).deletingPathExtension
        let patterns = [
            "^\(NSRegularExpression.escapedPattern(for: prefix))-(\\d+)$",
            "^\(NSRegularExpression.escapedPattern(for: prefix))(\\d+)$",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(base.startIndex..<base.endIndex, in: base)
            guard let match = regex.firstMatch(in: base, range: range),
                  match.numberOfRanges > 1,
                  let numberRange = Range(match.range(at: 1), in: base) else { continue }
            let numberStr = String(base[numberRange])
            guard numberStr.count == incrementLength, let number = Int(numberStr) else { continue }
            return number
        }
        return nil
    }

    private static func fnmatch(_ name: String, pattern: String) -> Bool {
        let normalized = pattern.hasPrefix("*") ? pattern : "*\(pattern)*"
        return (name as NSString).range(of: normalized, options: [.caseInsensitive]).location != NSNotFound
            || name.contains(pattern.replacingOccurrences(of: "*", with: ""))
    }
}
