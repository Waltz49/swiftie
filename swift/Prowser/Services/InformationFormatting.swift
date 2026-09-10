import Foundation

/// Display formatting for the information pane. Port of Python `utils.py` and `information_sidebar.py`.
enum InformationFormatting {
    private static let displayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let exifInputDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    static func formatFileSize(_ sizeBytes: Int) -> String {
        if sizeBytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(sizeBytes) / 1024.0)
        }
        if sizeBytes < 1024 * 1024 * 1024 {
            return String(format: "%.1f MB", Double(sizeBytes) / (1024.0 * 1024.0))
        }
        return String(format: "%.1f GB", Double(sizeBytes) / (1024.0 * 1024.0 * 1024.0))
    }

    static func normalizePathForDisplay(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let home = NSHomeDirectory()
        if trimmed.hasPrefix(home) {
            let relative = (trimmed as NSString).substring(from: home.count)
            if relative.isEmpty || relative == "/" { return "~" }
            let suffix = relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
            return "~/" + suffix.replacingOccurrences(of: "\\", with: "/")
        }
        return trimmed
    }

    static func elideValue(_ value: String, maxLen: Int = 40) -> String {
        guard value.count > maxLen else { return value }
        return String(value.prefix(maxLen - 3)) + "..."
    }

    static func formatGPS(latitude: Double, longitude: Double) -> String {
        func formatCoord(_ coord: Double) -> String {
            if coord == Double(Int(coord)) {
                return String(Int(coord))
            }
            return String(format: "%.3f", coord)
        }
        return "\(formatCoord(latitude)), \(formatCoord(longitude))"
    }

    static func formatAperture(_ fNumber: Double) -> String {
        "f/\(formatFloat(fNumber))"
    }

    static func formatFocalLength(_ millimeters: Double) -> String {
        "\(formatFloat(millimeters)) mm"
    }

    static func formatImageSize(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "" }
        let megapixels = Double(width * height) / 1_000_000.0
        return "\(width) × \(height)\n\(String(format: "%.2f", megapixels))MP"
    }

    static func formatFileDate(_ date: Date) -> String {
        displayDateFormatter.string(from: date)
    }

    static func formatExifDateString(_ raw: String) -> String? {
        if let date = exifInputDateFormatter.date(from: raw) {
            return displayDateFormatter.string(from: date)
        }
        return nil
    }

    static func formatFloat(_ value: Double) -> String {
        if value == Double(Int(value)) {
            return String(Int(value))
        }
        let formatted = String(format: "%.3f", value)
        if formatted.hasSuffix(".000") {
            return String(Int(value))
        }
        return formatted
    }

    static func compactElapsedDisplay(_ text: String) -> String {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return raw }
        let parts = raw.split(separator: ":").map(String.init)
        let totalSeconds: Int?
        switch parts.count {
        case 3:
            guard let h = Int(parts[0]), let m = Int(parts[1]), let s = Int(parts[2]) else { return raw }
            totalSeconds = h * 3600 + m * 60 + s
        case 2:
            guard let m = Int(parts[0]), let s = Int(parts[1]) else { return raw }
            totalSeconds = m * 60 + s
        case 1:
            guard let value = Int(parts[0]) else { return raw }
            totalSeconds = value
        default:
            return raw
        }
        guard let totalSeconds else { return raw }
        let total = max(0, totalSeconds)
        let h = total / 3600
        let rem = total % 3600
        let m = rem / 60
        let s = rem % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        if m > 0 {
            return String(format: "%d:%02d", m, s)
        }
        return String(s)
    }

    static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func isZeroValue(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty || trimmed == "none" || trimmed == "n/a" { return true }
        if let number = Double(trimmed) {
            return abs(number) < 0.0001
        }
        return trimmed == "0" || trimmed == "0.0" || trimmed == "0.00"
    }
}
