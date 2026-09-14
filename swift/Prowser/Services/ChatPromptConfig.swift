import Foundation

/// Persist chat system prompt library in `~/.swift-prowser/data/chat_system_prompts.json`.
/// Port of `chat_plugins/chat_prompt_config.py` and `chat_named_system_prompts.py`.
enum ChatPromptConfig {
    static let systemDefaultID = "__system_default__"
    static let defaultSystemPrompt = "You are a helpful assistant. Respond clearly and conversationally."

    struct NamedPrompt: Identifiable, Equatable {
        let id: String
        var name: String
        var text: String
    }

    struct SystemPromptStore: Equatable {
        var systemPrompt: String
        var activeNamedPromptID: String?
        var namedPrompts: [NamedPrompt]

        static func load(dataDirectory: URL) -> SystemPromptStore {
            let url = dataDirectory.appendingPathComponent("chat_system_prompts.json")
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return SystemPromptStore(
                    systemPrompt: defaultSystemPrompt,
                    activeNamedPromptID: nil,
                    namedPrompts: []
                )
            }
            let systemPrompt = (json["system_prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let prompts = (json["named_prompts"] as? [[String: Any]] ?? []).compactMap { item -> NamedPrompt? in
                guard let id = item["id"] as? String, !id.isEmpty else { return nil }
                return NamedPrompt(
                    id: id,
                    name: item["name"] as? String ?? "Untitled",
                    text: item["text"] as? String ?? ""
                )
            }
            var activeID = json["active_named_prompt_id"] as? String
            if activeID == systemDefaultID || activeID?.isEmpty == true {
                activeID = nil
            } else if let id = activeID, !prompts.contains(where: { $0.id == id }) {
                activeID = nil
            }
            return SystemPromptStore(
                systemPrompt: systemPrompt?.isEmpty == false ? systemPrompt! : defaultSystemPrompt,
                activeNamedPromptID: activeID,
                namedPrompts: prompts
            )
        }

        func save(dataDirectory: URL) {
            let payload: [String: Any] = [
                "system_prompt": systemPrompt,
                "active_named_prompt_id": activeNamedPromptID ?? "",
                "named_prompts": namedPrompts.map {
                    ["id": $0.id, "name": $0.name, "text": $0.text]
                },
            ]
            writeJSON(payload, to: dataDirectory.appendingPathComponent("chat_system_prompts.json"))
        }

        func activePromptText() -> String {
            if let activeNamedPromptID,
               let entry = namedPrompts.first(where: { $0.id == activeNamedPromptID }) {
                return entry.text
            }
            return systemPrompt
        }

        func activePromptName() -> String {
            if let activeNamedPromptID,
               let entry = namedPrompts.first(where: { $0.id == activeNamedPromptID }) {
                return entry.name
            }
            return "System default"
        }

        func activeLabel(sessionText: String) -> String {
            let saved = activePromptText().trimmingCharacters(in: .whitespacesAndNewlines)
            let session = sessionText.trimmingCharacters(in: .whitespacesAndNewlines)
            if session != saved { return "Custom" }
            return activePromptName()
        }
    }

    private static func writeJSON(_ payload: [String: Any], to url: URL) {
        let temp = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).tmp")
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        do {
            try data.write(to: temp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: temp, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temp)
        }
    }
}
