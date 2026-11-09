import Foundation

/// Port of `chat_plugins/chat_selection_image_trigger.py`.
@MainActor
enum ChatSelectionImageTrigger {
    static let selectionToken = "{}"
    static let maxChatImages = 4

    static func hasSelectionTrigger(_ text: String) -> Bool {
        text.contains(selectionToken)
    }

    static func stripTrigger(_ text: String) -> String {
        guard hasSelectionTrigger(text) else { return text }
        var stripped = text.replacingOccurrences(of: selectionToken, with: "")
        stripped = stripped.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func selectedImagesForChat(appState: AppState) -> [String] {
        ImageGenEditSourcePaths.activeImagePathsForEdit(appState: appState)
    }

    /// When ``keepTriggerInText`` is true (stored user messages), ``{}`` stays in the prompt for redo and edits; LM Studio text still strips it at send time.
    static func applySelectionTrigger(
        text: String,
        imagePaths: [String],
        appState: AppState,
        keepTriggerInText: Bool = false
    ) -> (text: String, imagePaths: [String]) {
        guard hasSelectionTrigger(text) else { return (text, imagePaths) }
        var outText = text
        if !keepTriggerInText {
            outText = stripTrigger(text)
        }
        let selected = selectedImagesForChat(appState: appState)
        if selected.isEmpty { return (outText, imagePaths) }
        return (outText, Array(selected.prefix(maxChatImages)))
    }
}
