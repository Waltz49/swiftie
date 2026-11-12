import AppKit

extension AppState {
    /// Window that should host copy confirmation (key window, else main browser).
    func copyFeedbackHostWindow() -> NSWindow? {
        if let key = NSApp.keyWindow, key.isVisible {
            return key
        }
        return BrowserWindowIdentity.resolveMainBrowserWindow()
    }

    /// Copy text to the system clipboard and show green copy feedback (Python `copy_text_to_clipboard`).
    func copyTextToClipboard(_ text: String, showFeedback: Bool = true, hostWindow: NSWindow? = nil) {
        let resolvedHost = hostWindow ?? copyFeedbackHostWindow()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if showFeedback {
            copyFeedback.show(hostWindow: resolvedHost)
        }
    }

    /// Image-gen prompt strip: preserve UTF-8 plain-text type after string copy.
    func copyImageGenPromptToClipboard(_ text: String, hostWindow: NSWindow? = nil) {
        copyTextToClipboard(text, hostWindow: hostWindow ?? copyFeedbackHostWindow())
        if let utf8 = ImageGenPromptTextEncoding.utf8Data(from: text) {
            NSPasteboard.general.setData(utf8, forType: NSPasteboard.PasteboardType("public.utf8-plain-text"))
        }
    }
}
