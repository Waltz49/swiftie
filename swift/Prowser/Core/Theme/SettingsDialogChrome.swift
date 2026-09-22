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

    /// Primary option label in preference rows (`macPreferenceRowTitle` / dialog `text_hex`).
    static var rowTitle: Color {
        isDarkAppearance()
            ? Color(hex: "#e2e2e2") ?? groupBoxTitle
            : Color(hex: "#1a1a1a") ?? .black
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
            ? Color(hex: "#606060") ?? Color(white: 0.38)
            : Color(hex: "#b0b0b0") ?? .gray
    }

    /// Group box title (`settings_dialog_theme.py` `header_hex`).
    static var groupBoxTitle: Color {
        isDarkAppearance()
            ? Color(hex: "#f0f0f0") ?? .white
            : Color(hex: "#1a1a1a") ?? .black
    }

    static var switchTrackOn: Color {
        Color(hex: "#29b94d") ?? Color(red: 0.16, green: 0.73, blue: 0.30)
    }

    static var switchTrackOff: Color {
        isDarkAppearance()
            ? Color(hex: "#636366") ?? Color(white: 0.40)
            : Color(hex: "#E9E9EA") ?? Color(white: 0.92)
    }
}
