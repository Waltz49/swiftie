import Foundation

/// Port of `chat_plugins/chat_prefix_postfix.py` persistence for settings UI.
struct PrefixPostfixEntry: Identifiable, Equatable {
    var id: String
    var text: String
    var useWithText: Bool
    var useWithImages: Bool
    var isPrefix: Bool
    var isPostfix: Bool
    var active: Bool
}

enum PrefixPostfixStore {
    private static let fileName = "chat_prefix_postfix.json"

    static func fileURL(dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent(fileName)
    }

    static func load(dataDirectory: URL) -> [PrefixPostfixEntry] {
        let url = fileURL(dataDirectory: dataDirectory)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["entries"] as? [[String: Any]] else {
            return []
        }
        return entries.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            return PrefixPostfixEntry(
                id: id,
                text: item["text"] as? String ?? "",
                useWithText: item["use_with_text"] as? Bool ?? false,
                useWithImages: item["use_with_images"] as? Bool ?? false,
                isPrefix: item["is_prefix"] as? Bool ?? false,
                isPostfix: item["is_postfix"] as? Bool ?? false,
                active: item["active"] as? Bool ?? true
            )
        }
    }

    static func save(_ entries: [PrefixPostfixEntry], dataDirectory: URL) {
        let url = fileURL(dataDirectory: dataDirectory)
        var config: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = json
        }
        config["entries"] = entries.map { entry in
            [
                "id": entry.id,
                "text": entry.text,
                "use_with_text": entry.useWithText,
                "use_with_images": entry.useWithImages,
                "is_prefix": entry.isPrefix,
                "is_postfix": entry.isPostfix,
                "active": entry.active,
            ] as [String: Any]
        }
        guard JSONSerialization.isValidJSONObject(config),
              let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    /// Port of ``apply_prefix_postfix_rules`` (list order preserved).
    static func applyRules(
        _ text: String,
        forImages: Bool,
        settings: [String: Any],
        dataDirectory: URL
    ) -> String {
        guard settings["imagegen_add_chat_prefix_postfix"] as? Bool ?? true else { return text }
        let entries = load(dataDirectory: dataDirectory)
        var prefixes: [String] = []
        var postfixes: [String] = []
        for entry in entries where entry.active {
            if forImages {
                guard entry.useWithImages else { continue }
            } else {
                guard entry.useWithText else { continue }
            }
            if shouldAddPrefix(text: text, entry: entry) {
                prefixes.append(entry.text)
            }
            if shouldAddPostfix(text: text, entry: entry) {
                postfixes.append(entry.text)
            }
        }
        if prefixes.isEmpty, postfixes.isEmpty { return text }
        return prefixes.joined() + text + postfixes.joined()
    }

    private static func normalizedCompareKey(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }

    private static func normalizedItemCount(haystack: String, item: String) -> Int {
        let normItem = normalizedCompareKey(item)
        guard !normItem.isEmpty else { return 0 }
        let hay = normalizedCompareKey(haystack)
        var count = 0
        var searchRange = hay.startIndex..<hay.endIndex
        while let found = hay.range(of: normItem, range: searchRange) {
            count += 1
            searchRange = found.upperBound..<hay.endIndex
        }
        return count
    }

    private static func shouldAddPrefix(text: String, entry: PrefixPostfixEntry) -> Bool {
        guard entry.isPrefix, !entry.text.isEmpty else { return false }
        return normalizedItemCount(haystack: text, item: entry.text) < 1
    }

    private static func shouldAddPostfix(text: String, entry: PrefixPostfixEntry) -> Bool {
        guard entry.isPostfix, !entry.text.isEmpty else { return false }
        let count = normalizedItemCount(haystack: text, item: entry.text)
        if entry.isPrefix {
            return count < 2
        }
        return count < 1
    }
}
