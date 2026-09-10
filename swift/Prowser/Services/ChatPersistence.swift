import Foundation

/// Read/write `~/.prowser/data/chat_session_*.json`. Port of `chat_persistence.py`.
enum ChatPersistence {
    private static let settingsFileName = "chat_session_settings.json"
    private static let dataFileName = "chat_session_data.json"

    static func preserveAcrossSessions(dataDirectory: URL) -> Bool {
        loadSettings(dataDirectory: dataDirectory)["preserve_across_sessions"] as? Bool ?? false
    }

    static func loadSettings(dataDirectory: URL) -> [String: Any] {
        loadSettingsFile(dataDirectory: dataDirectory)
    }

    static func saveSettings(
        dataDirectory: URL,
        preserveAcrossSessions: Bool,
        copyImagesToAssistant: Bool
    ) {
        let payload: [String: Any] = [
            "preserve_across_sessions": preserveAcrossSessions,
            "copy_images_to_assistant": copyImagesToAssistant,
        ]
        let url = dataDirectory.appendingPathComponent(settingsFileName)
        let temp = dataDirectory.appendingPathComponent("\(settingsFileName).tmp")
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

    static func loadMessages(dataDirectory: URL) -> [ChatMessage] {
        let url = dataDirectory.appendingPathComponent(dataFileName)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["messages"] as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { dict -> ChatMessage? in
            guard let role = dict["role"] as? String,
                  role == "user" || role == "assistant" else { return nil }
            let text = dict["text"] as? String ?? ""
            if let idString = dict["message_id"] as? String,
               let id = UUID(uuidString: idString) {
                return ChatMessage(id: id, role: role, text: text)
            }
            return ChatMessage(role: role, text: text)
        }
    }

    static func saveMessages(_ messages: [ChatMessage], dataDirectory: URL) {
        let payload: [String: Any] = [
            "messages": messages.map { message in
                [
                    "role": message.role,
                    "text": message.text,
                    "message_id": message.id.uuidString,
                    "image_paths": [] as [String],
                ] as [String: Any]
            },
        ]
        let url = dataDirectory.appendingPathComponent(dataFileName)
        let temp = url.deletingLastPathComponent().appendingPathComponent("\(dataFileName).tmp")
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

    static func clearPersistedFiles(dataDirectory: URL) {
        let dataURL = dataDirectory.appendingPathComponent(dataFileName)
        try? FileManager.default.removeItem(at: dataURL)
    }

    private static func loadSettingsFile(dataDirectory: URL) -> [String: Any] {
        let url = dataDirectory.appendingPathComponent(settingsFileName)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }
}
