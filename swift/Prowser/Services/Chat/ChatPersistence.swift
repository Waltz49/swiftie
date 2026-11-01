import Foundation

/// Port of `chat_plugins/chat_persistence.py`.
enum ChatPersistence {
    private static let settingsFileName = "chat_session_settings.json"
    private static let dataFileName = "chat_session_data.json"
    static let imagesDirName = "chat_session_images"

    struct SessionSettings: Equatable {
        var preserveAcrossSessions: Bool
        var copyImagesToAssistant: Bool
        var automaticCreate: Bool
    }

    static func loadSettings(dataDirectory: URL) -> SessionSettings {
        let url = dataDirectory.appendingPathComponent(settingsFileName)
        guard let dict = parseJSON(at: url) else {
            return SessionSettings(preserveAcrossSessions: false, copyImagesToAssistant: false, automaticCreate: false)
        }
        let copyImages: Bool
        if dict["copy_images_to_assistant"] != nil {
            copyImages = dict["copy_images_to_assistant"] as? Bool ?? false
        } else {
            copyImages = dict["show_assistant_images"] as? Bool ?? false
        }
        return SessionSettings(
            preserveAcrossSessions: dict["preserve_across_sessions"] as? Bool ?? false,
            copyImagesToAssistant: copyImages,
            automaticCreate: dict["automatic_create"] as? Bool ?? false
        )
    }

    static func saveSettings(_ settings: SessionSettings, dataDirectory: URL) {
        let payload: [String: Any] = [
            "preserve_across_sessions": settings.preserveAcrossSessions,
            "copy_images_to_assistant": settings.copyImagesToAssistant,
            "automatic_create": settings.automaticCreate,
        ]
        writeJSON(payload, to: dataDirectory.appendingPathComponent(settingsFileName))
    }

    static func sessionImagesDirectory(dataDirectory: URL) -> URL {
        let dir = dataDirectory.appendingPathComponent(imagesDirName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func loadMessages(dataDirectory: URL) -> [ChatMessage] {
        let url = dataDirectory.appendingPathComponent(dataFileName)
        guard let dict = parseJSON(at: url),
              let rawMessages = dict["messages"] as? [[String: Any]] else {
            return []
        }
        let imagesRoot = sessionImagesDirectory(dataDirectory: dataDirectory).standardizedFileURL.path
        var messages: [ChatMessage] = []
        for raw in rawMessages {
            guard let msg = messageFromDict(raw) else { continue }
            var keptPaths: [String] = []
            for path in msg.imagePaths {
                let abs = URL(fileURLWithPath: path).standardizedFileURL.path
                guard FileManager.default.isReadableFile(atPath: abs) else { continue }
                if msg.role == .assistant {
                    keptPaths.append(abs)
                } else if abs.hasPrefix(imagesRoot + "/") || abs.hasPrefix(imagesRoot + "\\") {
                    keptPaths.append(abs)
                }
            }
            var updated = msg
            updated.imagePaths = keptPaths
            if msg.role == .user {
                var sources = msg.sourceImagePaths.isEmpty ? keptPaths : msg.sourceImagePaths
                if sources.count != keptPaths.count {
                    sources = sources.count > keptPaths.count
                        ? Array(sources.prefix(keptPaths.count))
                        : keptPaths
                }
                updated.sourceImagePaths = ChatImagePaths.alignSourceImagePaths(
                    storedPaths: keptPaths,
                    sourcePaths: sources
                )
            }
            messages.append(updated)
        }
        return messages
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
        let images = sessionImagesDirectory(dataDirectory: dataDirectory)
        try? FileManager.default.removeItem(at: images)
    }

    private static func messageToDict(_ message: ChatMessage) -> [String: Any] {
        var payload: [String: Any] = [
            "role": message.role.rawValue,
            "text": message.text,
            "message_id": message.messageID,
            "image_paths": message.imagePaths,
        ]
        if !message.sourceImagePaths.isEmpty {
            payload["source_image_paths"] = message.sourceImagePaths
        }
        if let mode = message.imageGenAuto {
            payload["image_gen_auto"] = mode.rawValue
        }
        return payload
    }

    private static func messageFromDict(_ raw: [String: Any]) -> ChatMessage? {
        guard let roleRaw = raw["role"] as? String,
              let role = ChatRole(rawValue: roleRaw) else { return nil }
        guard let messageID = raw["message_id"] as? String, !messageID.isEmpty else { return nil }
        let text = raw["text"] as? String ?? ""
        let imagePaths = (raw["image_paths"] as? [String])?.filter { !$0.isEmpty } ?? []
        let sourcePaths = (raw["source_image_paths"] as? [String])?.filter { !$0.isEmpty } ?? imagePaths
        var auto: ChatImageGenAutoMode?
        if let a = raw["image_gen_auto"] as? String {
            auto = ChatImageGenAutoMode(rawValue: a)
        }
        return ChatMessage(
            role: role,
            text: text,
            messageID: messageID,
            imagePaths: imagePaths,
            sourceImagePaths: sourcePaths,
            imageGenAuto: auto
        )
    }

    private static func parseJSON(at url: URL) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              !data.isEmpty,
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
