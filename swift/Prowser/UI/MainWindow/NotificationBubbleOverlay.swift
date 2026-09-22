import SwiftUI

/// Stacked toast bubbles at the window lower-left, above the status bar when visible (Python `NotificationBubble`).
struct NotificationBubbleOverlay: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var status = appState.status
        let bubbles = status.bubbles
        let statusBarHeight = appState.effectiveStatusBarHeight
        let bottomPadding: CGFloat = statusBarHeight > 0 ? statusBarHeight + 6 : 12
        VStack(alignment: .leading, spacing: 6) {
            ForEach(bubbles) { bubble in
                Text(bubble.message)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(appState.theme.colors.dialogText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(appState.theme.colors.dialogBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(appState.theme.colors.defaultBorder, lineWidth: 1)
                    )
                    .opacity(bubble.opacity)
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, 5)
        .padding(.bottom, bottomPadding)
        .allowsHitTesting(false)
    }
}
