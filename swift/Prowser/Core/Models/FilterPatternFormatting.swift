import Foundation

/// Filter pattern display and normalization (Python `ImageBrowserConfig` parity).
@MainActor
enum FilterPatternFormatting {
    /// Canonical stored/matching pattern (always ends with `*` unless exactly `*`).
    static func normalizeForMatching(_ pattern: String?) -> String {
        AppConfig.normalizeFilterPattern(pattern)
    }

    /// Prime text fields and UI labels with a visible trailing `*`.
    static func forEditing(_ pattern: String?) -> String {
        guard let pattern, !pattern.isEmpty else { return "*" }
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "*" { return "*" }
        if trimmed.contains("*") || trimmed.contains("?") || trimmed.contains("[") {
            return trimmed
        }
        return trimmed + "*"
    }

    /// Save to `saved_filters` without trailing `*`.
    static func forStorage(_ pattern: String) -> String {
        var trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("*") {
            trimmed = String(trimmed.dropLast())
        }
        return trimmed
    }

    /// Label for empty-state / status bar buttons.
    static func buttonLabel(prefix: String) -> String {
        forEditing(prefix)
    }
}
