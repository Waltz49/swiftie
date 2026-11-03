import AppKit

enum PreferencesNSViewStringCollector {
    private static let minimumLabelPointSize: CGFloat = 12

    static func collect(from root: NSView) -> [String] {
        var strings: [String] = []
        walk(view: root, into: &strings)
        return dedupe(strings)
    }

    private static func walk(view: NSView, into strings: inout [String]) {
        if let header = view as? CollapsibleSectionHeaderButton {
            append(header.sectionTitle, into: &strings)
        } else if let field = view as? NSTextField, shouldIncludeTextField(field) {
            append(field.stringValue, into: &strings)
        } else if let button = view as? NSButton {
            if !(button is CollapsibleSectionHeaderButton),
               shouldIncludeOptionButtonTitle(button) {
                append(button.title, into: &strings)
            }
        } else if view is NSPopUpButton || view is NSComboBox {
            for subview in view.subviews {
                walk(view: subview, into: &strings)
            }
            return
        } else {
            collectAccessibilityLabel(from: view, into: &strings)
            for subview in view.subviews {
                walk(view: subview, into: &strings)
            }
            return
        }
        for subview in view.subviews {
            walk(view: subview, into: &strings)
        }
    }

    /// SwiftUI controls (e.g. `Picker` prompts) often expose labels only via accessibility.
    private static func collectAccessibilityLabel(from view: NSView, into strings: inout [String]) {
        guard !(view is NSButton) else { return }
        guard let label = view.accessibilityLabel(), !label.isEmpty else { return }
        guard shouldIncludeAccessibilityLabel(label, view: view) else { return }
        append(label, into: &strings)
    }

    private static func shouldIncludeAccessibilityLabel(_ text: String, view: NSView) -> Bool {
        if let field = view as? NSTextField, field.isEditable { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if trimmed.count < 2 { return false }
        return true
    }

    /// Plain / radio-style buttons that label an option (not OK, Choose…, gear icons, etc.).
    static func shouldIncludeOptionButtonTitle(_ button: NSButton) -> Bool {
        let title = button.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        if title.hasPrefix("\u{25BC} ") || title.hasPrefix("\u{25B6} ") { return false }
        let lower = title.lowercased()
        let excludedExact: Set<String> = [
            "choose…", "choose...", "apply", "clear", "ok", "cancel", "save", "close",
            "defaults", "edit settings", "remove sample",
        ]
        if excludedExact.contains(lower) { return false }
        if title.hasSuffix("…"), title.count <= 28 { return false }
        if button.image != nil, button.title.isEmpty { return false }
        if !button.isBordered { return true }
        switch button.bezelStyle {
        case .shadowlessSquare, .inline, .recessed:
            return true
        default:
            return false
        }
    }

    static func shouldIncludeTextField(_ field: NSTextField) -> Bool {
        if field.isEditable { return false }
        if field.isBezeled && field.isBordered { return false }
        let pointSize = field.font?.pointSize
            ?? (field.cell as? NSTextFieldCell)?.font?.pointSize
            ?? 13
        if pointSize < minimumLabelPointSize { return false }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty
    }

    private static func append(_ raw: String, into strings: inout [String]) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        strings.append(trimmed)
    }

    private static func dedupe(_ strings: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for string in strings {
            let key = string.lowercased()
            if seen.insert(key).inserted {
                ordered.append(string)
            }
        }
        return ordered
    }
}
