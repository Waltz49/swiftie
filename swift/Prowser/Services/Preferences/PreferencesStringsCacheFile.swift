import Foundation

enum PreferencesStringKind: String, Codable, Sendable {
    case label
    case header
    /// Reserved for future dynamic values (e.g. LoRA names) merged at search time.
    case value
}

struct PreferencesStringEntry: Codable, Hashable, Sendable {
    var text: String
    var kind: PreferencesStringKind
}

struct PreferencesStringsCacheFile: Codable, Sendable {
    static let formatVersion = 4

    var formatVersion: Int
    var visibilityFingerprint: String
    var scannedAt: Date
    var tabs: [String: [PreferencesStringEntry]]

    init(
        visibilityFingerprint: String,
        scannedAt: Date = Date(),
        tabs: [String: [PreferencesStringEntry]]
    ) {
        formatVersion = Self.formatVersion
        self.visibilityFingerprint = visibilityFingerprint
        self.scannedAt = scannedAt
        self.tabs = tabs
    }

    static func visibilityFingerprint(minBundle: Bool) -> String {
        let imageGen = BundleCapabilities.imageGenUIEnabled
        return "minBundle=\(minBundle ? 1 : 0);imageGenUI=\(imageGen ? 1 : 0)"
    }

    func isValid(forFingerprint fingerprint: String) -> Bool {
        formatVersion == Self.formatVersion && visibilityFingerprint == fingerprint
    }
}

enum PreferencesStringMatching: Sendable {
    static func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Case-insensitive match when the query is a prefix of the full string or of any word in it.
    static func prefixMatches(query: String, candidate: String) -> Bool {
        let q = normalizedQuery(query)
        if q.isEmpty { return true }
        let lowerQ = q.lowercased()
        let lowered = candidate.lowercased()
        if lowered.hasPrefix(lowerQ) { return true }
        for word in lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            if word.hasPrefix(lowerQ) { return true }
        }
        return false
    }

    static func tabMatches(
        tabTitle: String,
        query: String,
        entries: [PreferencesStringEntry]
    ) -> Bool {
        let q = normalizedQuery(query)
        if q.isEmpty { return true }
        if prefixMatches(query: q, candidate: tabTitle) { return true }
        return entries.contains { prefixMatches(query: q, candidate: $0.text) }
    }
}
