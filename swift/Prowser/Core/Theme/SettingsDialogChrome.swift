import AppKit
import SwiftUI

/// Fixed settings-window chrome — port of `settings/widgets/settings_dialog_theme.py`.
/// Settings UI does not follow the app's `dialog_background_hex`.
enum SettingsDialogChrome {
    static func isDarkAppearance() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static var background: Color {
        isDarkAppearance()
            ? Color(hex: "#2a2a2a") ?? Color(white: 0.16)
            : Color(hex: "#ececec") ?? Color(white: 0.93)
    }

    static var text: Color {
        isDarkAppearance()
            ? Color(hex: "#b6b6b6") ?? .gray
            : .black
    }

    static var secondaryText: Color {
        isDarkAppearance()
            ? Color(hex: "#888888") ?? .gray
            : Color(white: 0.35)
    }

    static var sectionBackground: Color {
        isDarkAppearance()
            ? Color(hex: "#323232") ?? Color(white: 0.20)
            : Color(hex: "#f5f5f5") ?? Color(white: 0.96)
    }

    static var border: Color {
        isDarkAppearance()
            ? Color(hex: "#444444") ?? Color(white: 0.27)
            : Color(hex: "#c0c0c0") ?? .gray
    }
}
