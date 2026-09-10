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
        copyImagesToAssistant: Bool,
        automaticCreate: Bool
    ) {
        let payload: [String: Any] = [
            "preserve_across_sessions": preserveAcrossSessions,
            "copy_images_to_assistant": copyImagesToAssistant,
            "automatic_create": automaticCreate,
        ]
        writeJSON(payload, to: dataDirectory.appendingPathComponent(settingsFileName))
    }

    static func loadMessages(dataDirectory: URL) -> [ChatMessage] {
        let url = dataDirectory.appendingPathComponent(dataFileName)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["messages"] as? [[String: Any]] else {
            return []
        }
        return raw.compactMap(messageFromDict)
    }

    static func saveMessages(_ messages: [ChatMessage], dataDirectory: URL) {
        let payload: [String: Any] = [
            "messages": messages.map(messageToDict),
        ]
        writeJSON(payload, to: dataDirectory.appendingPathComponent(dataFileName))
    }

    static func clearPersistedFiles(dataDirectory: URL) {
        let dataURL = dataDirectory.appendingPathComponent(dataFileName)
        try? FileManager.default.removeItem(at: dataURL)
        ChatImageStore.clearSessionImages(dataDirectory: dataDirectory)
    }

    private static func messageToDict(_ message: ChatMessage) -> [String: Any] {
        var payload: [String: Any] = [
            "role": message.role,
            "text": message.text,
            "message_id": message.id.uuidString,
            "image_paths": message.imagePaths,
        ]
        if !message.sourceImagePaths.isEmpty {
            payload["source_image_paths"] = message.sourceImagePaths
        }
        if let mode = message.imageGenAuto {
            payload["image_gen_auto"] = mode
        }
        return payload
    }

    private static func messageFromDict(_ dict: [String: Any]) -> ChatMessage? {
        guard let role = dict["role"] as? String,
              role == "user" || role == "assistant" else { return nil }
        let text = dict["text"] as? String ?? ""
        let imagePaths = (dict["image_paths"] as? [String] ?? []).filter { !$0.isEmpty }
        let sourcePaths = (dict["source_image_paths"] as? [String] ?? imagePaths).filter { !$0.isEmpty }
        let auto = dict["image_gen_auto"] as? String
        let imageGenAuto = (auto == "create" || auto == "edit") ? auto : nil
        if let idString = dict["message_id"] as? String,
           let id = UUID(uuidString: idString) {
            return ChatMessage(
                id: id,
                role: role,
                text: text,
                imagePaths: imagePaths,
                sourceImagePaths: sourcePaths,
                imageGenAuto: imageGenAuto
            )
        }
        return ChatMessage(
            role: role,
            text: text,
            imagePaths: imagePaths,
            sourceImagePaths: sourcePaths,
            imageGenAuto: imageGenAuto
        )
    }

    private static func loadSettingsFile(dataDirectory: URL) -> [String: Any] {
        let url = dataDirectory.appendingPathComponent(settingsFileName)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
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
