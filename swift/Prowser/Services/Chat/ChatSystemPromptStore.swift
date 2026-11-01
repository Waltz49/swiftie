import Foundation

struct ChatNamedPrompt: Identifiable, Equatable {
    var id: String
    var name: String
    var text: String
}

/// Port of `chat_plugins/chat_prompt_config.py` / `chat_named_system_prompts.py`.
enum ChatSystemPromptStore {
    static let systemDefaultID = "__system_default__"
    private static let fileName = "chat_system_prompts.json"
    static let defaultPromptText = "You are a helpful assistant. Respond clearly and conversationally."

    struct Config: Equatable {
        var systemPrompt: String
        var activeNamedPromptID: String
        var namedPrompts: [ChatNamedPrompt]
    }

    static func load(dataDirectory: URL) -> Config {
        let url = dataDirectory.appendingPathComponent(fileName)
        if let dict = parseJSON(at: url) {
            return normalize(dict)
        }
        let defaultConfig = defaultConfigValue()
        save(defaultConfig, dataDirectory: dataDirectory)
        return defaultConfig
    }

    static func save(_ config: Config, dataDirectory: URL) {
        var ordered = config
        reorderNamedPromptsMRU(&ordered)
        let payload: [String: Any] = [
            "system_prompt": ordered.systemPrompt,
            "active_named_prompt_id": ordered.activeNamedPromptID,
            "named_prompts": ordered.namedPrompts.map { item in
                ["id": item.id, "name": item.name, "text": item.text] as [String: Any]
            },
        ]
        writeJSON(payload, to: dataDirectory.appendingPathComponent(fileName))
    }

    static func activePromptText(config: Config) -> String {
        let trimmedActive = config.activeNamedPromptID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedActive.isEmpty || trimmedActive == systemDefaultID {
            let base = config.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return base.isEmpty ? defaultPromptText : config.systemPrompt
        }
        if let entry = config.namedPrompts.first(where: { $0.id == trimmedActive }) {
            return entry.text
        }
        return config.systemPrompt
    }

    static func activePromptName(config: Config) -> String {
        let trimmedActive = config.activeNamedPromptID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedActive.isEmpty || trimmedActive == systemDefaultID {
            return "System default"
        }
        return config.namedPrompts.first(where: { $0.id == trimmedActive })?.name ?? "System default"
    }

    static func activeLabel(sessionText: String, config: Config) -> String {
        let saved = activePromptText(config: config)
        if sessionText.trimmingCharacters(in: .whitespacesAndNewlines)
            != saved.trimmingCharacters(in: .whitespacesAndNewlines) {
            return "Custom"
        }
        return activePromptName(config: config)
    }

    /// Backward-compatible alias for menu checkmarks.
    static func activeLabel(config: Config) -> String {
        activePromptName(config: config)
    }

    private static func defaultConfigValue() -> Config {
        Config(systemPrompt: defaultPromptText, activeNamedPromptID: "", namedPrompts: [])
    }

    private static func normalize(_ raw: [String: Any]) -> Config {
        var config = defaultConfigValue()
        if let prompt = raw["system_prompt"] as? String, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            config.systemPrompt = prompt
        }
        if let active = raw["active_named_prompt_id"] as? String {
            config.activeNamedPromptID = active == systemDefaultID ? "" : active
        }
        if let items = raw["named_prompts"] as? [[String: Any]] {
            config.namedPrompts = items.compactMap { item in
                guard let id = item["id"] as? String, !id.isEmpty else { return nil }
                let name = (item["name"] as? String) ?? (item["label"] as? String) ?? "Untitled"
                return ChatNamedPrompt(
                    id: id,
                    name: name,
                    text: item["text"] as? String ?? ""
                )
            }
        }
        validateActiveNamedPromptID(&config)
        return config
    }

    /// Drop stale ``activeNamedPromptID`` values (port of Python ``ChatPromptStore.load``).
    static func validateActiveNamedPromptID(_ config: inout Config) {
        let active = config.activeNamedPromptID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !active.isEmpty else { return }
        if !config.namedPrompts.contains(where: { $0.id == active }) {
            config.activeNamedPromptID = ""
        }
    }

    private static func reorderNamedPromptsMRU(_ config: inout Config) {
        let active = config.activeNamedPromptID
        guard !active.isEmpty,
              let idx = config.namedPrompts.firstIndex(where: { $0.id == active }) else { return }
        let entry = config.namedPrompts.remove(at: idx)
        config.namedPrompts.insert(entry, at: 0)
    }

    private static func parseJSON(at url: URL) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func writeJSON(_ object: [String: Any], to url: URL) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        let temp = url.deletingPathExtension().appendingPathExtension("json.tmp")
        try? data.write(to: temp, options: .atomic)
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: temp)
    }
}
