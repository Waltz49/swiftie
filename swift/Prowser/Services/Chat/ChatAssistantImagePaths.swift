import Foundation

/// Port of ``chat_plugins/chat_assistant_image_paths.py``.
enum ChatAssistantImagePaths {
    @MainActor
    static func normalize(_ paths: [String]) -> [String] {
        var out: [String] = []
        for path in paths where !path.isEmpty {
            let abs = URL(fileURLWithPath: path).standardizedFileURL.path
            guard FileManager.default.isReadableFile(atPath: abs) else { continue }
            if out.contains(abs) { continue }
            out.append(abs)
            if out.count >= ChatSelectionImageTrigger.maxChatImages { break }
        }
        return out
    }
}
