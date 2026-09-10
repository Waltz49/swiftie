import SwiftUI

/// Shared dialog chrome from the active theme palette.
struct ThemeDialogStyle: ViewModifier {
    @Environment(\.themeColors) private var colors

    func body(content: Content) -> some View {
        content
            .foregroundStyle(colors.dialogText)
            .background(colors.dialogBackground)
    }
}

extension View {
    func themeDialogStyle() -> some View {
        modifier(ThemeDialogStyle())
    }
}
