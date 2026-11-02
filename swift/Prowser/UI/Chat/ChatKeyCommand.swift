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
}
