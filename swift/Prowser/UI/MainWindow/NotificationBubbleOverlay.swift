import SwiftUI

/// Stacked toast bubbles anchored above the status bar (Python `NotificationBubble`).
struct NotificationBubbleOverlay: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let bubbles = appState.status.bubbles
        let bottomPadding: CGFloat = appState.effectiveStatusBarHeight > 0 ? 30 : 12
        VStack(alignment: .leading, spacing: 6) {
            ForEach(bubbles) { bubble in
                Text(bubble.message)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(appState.theme.colors.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(appState.theme.colors.sidebarHeaderBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(appState.theme.colors.sidebarHeaderBorder, lineWidth: 1)
                    )
                    .opacity(bubble.opacity)
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, 12)
        .padding(.bottom, bottomPadding)
        .allowsHitTesting(false)
    }
}
