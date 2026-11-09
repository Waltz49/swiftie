import AppKit

/// Port of Python ``chat_ui_common.cmd_enter_pressed``.
enum ChatKeyCommand {
    static func isCommandReturn(_ event: NSEvent) -> Bool {
        guard event.keyCode == 36 || event.keyCode == 76 else { return false }
        return isCommandReturn(modifiers: event.modifierFlags)
    }

    /// Used from ``NSTextView`` ``doCommandBy`` where the selector already implies Return.
    static func isCommandReturn(modifiers: NSEvent.ModifierFlags) -> Bool {
        let mods = modifiers.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.command) else { return false }
        let withoutCommand = mods.subtracting([.command, .control])
        return withoutCommand.isEmpty || withoutCommand == .numericPad
    }

    /// Plain Escape (not ⇧Escape history shortcut).
    static func isPlainEscape(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53 else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return mods.isEmpty || mods == .numericPad
    }

    /// Port of Python ``_chat_cmd_r_key_event`` (⌘R in chat pane — redo / refresh LM Studio when unavailable).
    static func isChatCommandR(_ event: NSEvent) -> Bool {
        guard event.charactersIgnoringModifiers?.lowercased() == "r" else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.command) else { return false }
        let withoutCommand = mods.subtracting([.command, .control, .numericPad])
        guard withoutCommand.isEmpty else { return false }
        return true
    }

    /// Compose field, inline message edit, or their scroll hosts (Python chat child focus).
    static func isChatTextInputResponder(_ responder: NSResponder) -> Bool {
        if responder is ChatComposePromptNSTextView || responder is ChatMessageEditNSTextView {
            return true
        }
        if let textView = responder as? NSTextView {
            if textView.delegate is ChatComposePromptTextView.Coordinator { return true }
            if textView.delegate is ChatMessageEditTextView.Coordinator { return true }
        }
        if let view = responder as? NSView {
            var current: NSView? = view
            while let candidate = current {
                if candidate is ChatComposePromptHostView || candidate is ChatMessageEditHostView { return true }
                if candidate is ChatComposePromptNSTextView || candidate is ChatMessageEditNSTextView { return true }
                if let scroll = candidate as? NSScrollView,
                   scroll.documentView is ChatComposePromptNSTextView
                    || scroll.documentView is ChatMessageEditNSTextView {
                    return true
                }
                current = candidate.superview
            }
        }
        return false
    }

    @MainActor
    static func isChatPaneKeyboardTarget(event: NSEvent, appState: AppState) -> Bool {
        guard appState.isChatVisible else { return false }
        let display = SidebarPaneSplitModel.leftDisplayPaneVisibility(appState: appState)
        guard display[2] else { return false }
        guard let responder = (event.window ?? NSApp.keyWindow)?.firstResponder else { return false }
        return isChatTextInputResponder(responder)
    }
}
