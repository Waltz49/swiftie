import Foundation

struct ChatFavoritePrompt: Identifiable, Equatable {
    var id: String
    var label: String
    var text: String
    var imagePaths: [String]
}

/// Port of `chat_user_prompts.json` persistence.
enum ChatUserPromptStore {
    private static let fileName = "chat_user_prompts.json"

    struct Config: Equatable {
        var selectedFavoriteID: String
        var favoritePrompts: [ChatFavoritePrompt]
    }

    static func load(dataDirectory: URL) -> Config {
        let url = dataDirectory.appendingPathComponent(fileName)
        if let dict = parseJSON(at: url) {
            return normalize(dict)
        }
        let defaultConfig = Config(selectedFavoriteID: "", favoritePrompts: [])
        save(defaultConfig, dataDirectory: dataDirectory)
        return defaultConfig
    }

    static func newEntryID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10))
    }

    static func save(_ config: Config, dataDirectory: URL) {
        let payload: [String: Any] = [
            "selected_favorite_prompt_id": config.selectedFavoriteID,
            "favorite_prompts": config.favoritePrompts.map { item in
                [
                    "id": item.id,
                    "name": item.label,
                    "text": item.text,
                    "image_paths": item.imagePaths,
                ] as [String: Any]
            },
        ]
        writeJSON(payload, to: dataDirectory.appendingPathComponent(fileName))
    }

    private static func normalize(_ raw: [String: Any]) -> Config {
        var config = Config(selectedFavoriteID: "", favoritePrompts: [])
        if let sel = raw["selected_favorite_prompt_id"] as? String {
            config.selectedFavoriteID = sel
        }
        if let items = raw["favorite_prompts"] as? [[String: Any]] {
            config.favoritePrompts = items.compactMap { item in
                guard let id = item["id"] as? String, !id.isEmpty else { return nil }
                let paths = (item["image_paths"] as? [String])?.filter { path in
                    !path.isEmpty && FileManager.default.fileExists(atPath: path)
                } ?? []
                let name = (item["name"] as? String) ?? (item["label"] as? String) ?? "Untitled"
                return ChatFavoritePrompt(
                    id: id,
                    label: name,
                    text: item["text"] as? String ?? "",
                    imagePaths: paths
                )
            }
        }
        return config
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
