import Foundation

/// Short path labels that extend parent segments only when basenames collide within a batch.
@MainActor
enum PathLabelDisambiguation {
    // MARK: - Batches

    static func favoriteLabels(config: AppConfig, imageExtensions: [String]) -> [String: String] {
        let stored = config.favoriteDirectories().compactMap { path -> String? in
            guard let path else { return nil }
            guard isEligibleFavorite(stored: path, imageExtensions: imageExtensions) else { return nil }
            return path
        }
        return disambiguate(storedPaths: stored)
    }

    static func moveDestinationLabels(
        config: AppConfig,
        lastDropLocation: String?
    ) -> [String: String] {
        var stored: [String] = []
        for path in config.moveDestinations() {
            guard let path, isEligibleMoveDestination(stored: path) else { continue }
            stored.append(path)
        }
        if let lastDropLocation,
           isEligibleLastDropDirectory(stored: lastDropLocation) {
            stored.append(lastDropLocation)
        }
        return disambiguate(storedPaths: stored)
    }

    // MARK: - Eligibility

    static func isEligibleFavorite(stored: String, imageExtensions: [String]) -> Bool {
        switch SettingsPathValidation.validateFavoriteDestinationPath(stored, imageExtensions: imageExtensions) {
        case .valid:
            return true
        case .empty, .invalid:
            return false
        }
    }

    static func isEligibleMoveDestination(stored: String) -> Bool {
        switch SettingsPathValidation.validateMoveDestinationPath(stored) {
        case .valid:
            return true
        case .empty, .invalid:
            return false
        }
    }

    static func isEligibleLastDropDirectory(stored: String) -> Bool {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let expanded = expandedStandardPath(trimmed)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    static func expandedStandardPath(_ stored: String) -> String {
        let expanded = (stored.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    static func tooltipPath(_ stored: String) -> String {
        expandedStandardPath(stored)
    }

    // MARK: - Core algorithm

    /// Keys are stored config/session path strings; values are short UI labels.
    static func disambiguate(storedPaths: [String]) -> [String: String] {
        var seen = Set<String>()
        let keys = storedPaths.filter { path in
            guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            return seen.insert(path).inserted
        }
        guard !keys.isEmpty else { return [:] }

        var depths: [String: Int] = [:]
        for key in keys {
            depths[key] = 1
        }
        var labels: [String: String] = [:]

        for _ in 0..<64 {
            for key in keys {
                labels[key] = label(forStoredPath: key, depth: depths[key] ?? 1)
            }

            let grouped = Dictionary(grouping: keys, by: { labels[$0, default: ""] })
            let collidingGroups = grouped.values.filter { $0.count > 1 }
            if collidingGroups.isEmpty { break }

            var progressed = false
            for group in collidingGroups {
                for key in group {
                    let display = displayPath(forStoredPath: key)
                    let comps = pathComponents(displayPath: display)
                    let depth = depths[key] ?? 1
                    let minWhenColliding = minimumLabelDepthWhenDisambiguating(
                        displayPath: display,
                        components: comps
                    )
                    let nextDepth = max(depth + 1, minWhenColliding)
                    if nextDepth <= comps.count {
                        depths[key] = nextDepth
                    } else {
                        depths[key] = comps.count + 1
                    }
                    progressed = true
                }
            }
            if !progressed { break }
        }

        return labels
    }

    private static func displayPath(forStoredPath stored: String) -> String {
        StatusBarFormatter.displayPath(expandedStandardPath(stored))
    }

    private static func pathComponents(displayPath: String) -> [String] {
        var path = displayPath
        while path.hasSuffix("/"), path.count > 1 {
            path.removeLast()
        }
        if path.isEmpty { return [] }
        if path == "~" { return ["~"] }
        if path.hasPrefix("~/") {
            let tail = String(path.dropFirst(2))
            if tail.isEmpty { return ["~"] }
            return ["~"] + tail.split(separator: "/").map(String.init)
        }
        if path.hasPrefix("/") {
            return path.dropFirst().split(separator: "/").map(String.init)
        }
        return path.split(separator: "/").map(String.init)
    }

    /// When basenames collide, use at least `parent/leaf` — except filesystem-root dirs (`/tmp` → `/tmp`).
    private static func minimumLabelDepthWhenDisambiguating(
        displayPath: String,
        components: [String]
    ) -> Int {
        if displayPath.hasPrefix("/"), components.count == 1 {
            return 2
        }
        if components.count <= 1 {
            return 1
        }
        return min(2, components.count)
    }

    private static func label(forStoredPath stored: String, depth: Int) -> String {
        let display = displayPath(forStoredPath: stored)
        let components = pathComponents(displayPath: display)
        guard !components.isEmpty, depth > 0 else { return display }
        if depth > components.count {
            return display
        }

        let suffix = Array(components.suffix(depth))
        if display.hasPrefix("~/") || display == "~" {
            if suffix.first == "~" {
                if suffix.count == 1 { return "~" }
                return "~/" + suffix.dropFirst().joined(separator: "/")
            }
            return suffix.joined(separator: "/")
        }

        return suffix.joined(separator: "/")
    }
}
