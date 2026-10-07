import SwiftUI

/// Port of Python ``ClickableImageGenIndicatorLabel`` (status-bar task dot).
struct StatusBarJobIndicator: View {
    let kind: String
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 10, height: 10)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private var indicatorColor: Color {
        switch kind {
        case "caption":
            return .yellow
        case "cooldown":
            return .blue
        case "cleanup":
            return .purple
        default:
            return .red
        }
    }
}
