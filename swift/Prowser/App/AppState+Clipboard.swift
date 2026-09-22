import AppKit

extension AppState {
    /// Copy text to the system clipboard and show green copy feedback (Python `copy_text_to_clipboard`).
    func copyTextToClipboard(_ text: String, showFeedback: Bool = true) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if showFeedback {
            copyFeedback.show()
        }
    }
}
