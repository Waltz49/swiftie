import Foundation

/// Status bar label formatting (Python `status_bar_config.py`).
@MainActor
enum StatusBarFormatter {
    static func sortLabel(mode: SortMode, reversed: Bool) -> String {
        switch mode {
        case .custom:
            return reversed ? "Custom ↓" : "Custom ↑"
        case .name:
            return reversed ? "Name ↓" : "Name ↑"
        case .size, .filesize:
            return reversed ? "Size ↓" : "Size ↑"
        case .random:
            return "Random ↑"
        case .duplicates:
            return "Duplicates"
        case .exifDate:
            return reversed ? "Month ↓" : "Month ↑"
        case .exifYear:
            return reversed ? "Year ↓" : "Year ↑"
        default:
            return reversed ? "Date ↓" : "Date ↑"
        }
    }

    static func filterLabel(pattern: String) -> String {
        "Filter: \(FilterPatternFormatting.forEditing(pattern))"
    }

    static func fitModeLabel(actualSize: Bool) -> String {
        actualSize ? "Actual Size" : "Fit to Window"
    }

    static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    static func dimensionsLabel(path: String?, metadataCache: MetadataCacheService) -> String {
        guard let path else { return "0 x 0" }
        if let size = metadataCache.pixelSize(path: path) {
            return "\(size.width) x \(size.height)"
        }
        return "0 x 0"
    }

    struct DateLabel {
        let text: String
        let usesExifDate: Bool?
    }

    static func dateLabel(path: String?, useExifDate: Bool, metadataCache: MetadataCacheService) -> DateLabel {
        guard let path else { return DateLabel(text: "--", usesExifDate: nil) }
        let exifTs = metadataCache.fileTimestamp(path: path, preferExif: true)
        let fileTs = metadataCache.fileTimestamp(path: path, preferExif: false)
        let timestamp = useExifDate && exifTs > 0 ? exifTs : fileTs
        guard timestamp > 0 else { return DateLabel(text: "--", usesExifDate: nil) }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        let usedExif = useExifDate && exifTs > 0 && timestamp == exifTs
        return DateLabel(text: formatter.string(from: date), usesExifDate: usedExif)
    }

    static func fileCountLabel(
        displayedPaths: [String],
        directory: String?,
        filterPattern: String,
        extensions: [String],
        backgroundIndicatorPrefix: String = ""
    ) -> String {
        let displayedCount = displayedPaths.count
        let multipleDirs = multipleDirectoriesIndicator(displayedCount: displayedCount, paths: displayedPaths)
        guard let directory else {
            if displayedCount > 0 {
                return "\(backgroundIndicatorPrefix)\(displayedCount)\(multipleDirs)"
            }
            return "\(backgroundIndicatorPrefix)No files"
        }

        let total = DirectoryScanner.scanDirectory(
            at: directory,
            extensions: extensions,
            filterPattern: filterPattern
        ).count

        if total > 0 || displayedCount > 0 {
            return "\(backgroundIndicatorPrefix)\(displayedCount) files (Directory)\(multipleDirs)"
        }
        return "\(backgroundIndicatorPrefix)No files"
    }

    private static func multipleDirectoriesIndicator(displayedCount: Int, paths: [String]) -> String {
        guard displayedCount > 0, !paths.isEmpty else { return "" }
        var seenPrefix: String?
        for path in paths {
            let prefix: String
            if let idx = path.lastIndex(of: "/") {
                prefix = String(path[..<idx])
            } else {
                prefix = ""
            }
            if let seenPrefix {
                if prefix != seenPrefix { return " (>1 dir)" }
            } else {
                seenPrefix = prefix
            }
        }
        return ""
    }
}
