import Foundation

/// Insert browser selection into chat via ``{}`` in the user message.
/// Port of `chat_plugins/chat_selection_image_trigger.py`.
enum ChatSelectionImageTrigger {
    static let trigger = "{}"

    static func hasTrigger(_ text: String) -> Bool {
        text.contains(trigger)
    }

    static func stripTrigger(_ text: String) -> String {
        guard hasTrigger(text) else { return text }
        let stripped = text.replacingOccurrences(of: trigger, with: "")
        return stripped.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func apply(
        text: String,
        imagePaths: [String],
        selectedPaths: [String],
        keepTriggerInText: Bool = false
    ) -> (text: String, imagePaths: [String]) {
        guard hasTrigger(text) else { return (text, imagePaths) }
        let storedText = keepTriggerInText ? text : stripTrigger(text)
        let selected = normalizedSelection(selectedPaths)
        if !selected.isEmpty {
            return (storedText, selected)
        }
        return (storedText, imagePaths)
    }

    static func normalizedSelection(_ paths: [String]) -> [String] {
        var result: [String] = []
        for path in paths {
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { continue }
            let abs = URL(fileURLWithPath: path).path
            if !result.contains(abs) {
                result.append(abs)
            }
            if result.count >= ChatImageStore.maxImages { break }
        }
        return result
    }
}
