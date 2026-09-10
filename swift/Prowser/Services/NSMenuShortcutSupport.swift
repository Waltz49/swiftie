import AppKit

/// Right-aligns shortcut labels in `NSMenu` items (Python/Qt `"\(title)\t\(shortcut)"` parity).
enum NSMenuShortcutSupport {
    static func apply(display shortcut: String, to item: NSMenuItem) {
        guard !shortcut.isEmpty else { return }

        var modifiers = NSEvent.ModifierFlags()
        var key = shortcut

        for (symbol, flag) in [
            ("⌘", NSEvent.ModifierFlags.command),
            ("⇧", NSEvent.ModifierFlags.shift),
            ("⌃", NSEvent.ModifierFlags.control),
            ("⌥", NSEvent.ModifierFlags.option),
        ] {
            if key.contains(symbol) {
                modifiers.insert(flag)
                key = key.replacingOccurrences(of: symbol, with: "")
            }
        }

        key = key.trimmingCharacters(in: .whitespaces)

        if let functionKey = functionKeyEquivalent(for: key) {
            item.keyEquivalent = functionKey
        } else if let first = key.lowercased().first {
            item.keyEquivalent = String(first)
        }

        item.keyEquivalentModifierMask = modifiers
    }

    private static func functionKeyEquivalent(for label: String) -> String? {
        guard label.hasPrefix("F"), let number = Int(label.dropFirst()) else { return nil }
        let code: Int?
        switch number {
        case 1: code = NSF1FunctionKey
        case 2: code = NSF2FunctionKey
        case 3: code = NSF3FunctionKey
        case 4: code = NSF4FunctionKey
        case 5: code = NSF5FunctionKey
        case 6: code = NSF6FunctionKey
        case 7: code = NSF7FunctionKey
        case 8: code = NSF8FunctionKey
        case 9: code = NSF9FunctionKey
        case 10: code = NSF10FunctionKey
        case 11: code = NSF11FunctionKey
        case 12: code = NSF12FunctionKey
        case 13: code = NSF13FunctionKey
        case 14: code = NSF14FunctionKey
        case 15: code = NSF15FunctionKey
        case 16: code = NSF16FunctionKey
        case 17: code = NSF17FunctionKey
        case 18: code = NSF18FunctionKey
        case 19: code = NSF19FunctionKey
        case 20: code = NSF20FunctionKey
        default: code = nil
        }
        guard let code else { return nil }
        return String(UnicodeScalar(code)!)
    }
}
