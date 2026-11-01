import SwiftUI

/// Message action strip sizing (Python ``chat_ui_common._ICON_BTN_SIZE`` / ``_ICON_DISPLAY_PX``).
enum ChatMessageChrome {
    static let buttonSize: CGFloat = 22
    static let iconSize: CGFloat = 14
    static let outerHorizontalPadding: CGFloat = 6
    static let outerVerticalPadding: CGFloat = 4
}

struct ChatMessageIconButton: View {
    @Environment(AppState.self) private var appState

    let normalName: String
    let hoverName: String
    var tooltip: String = ""
    var enabled: Bool = true
    var highlighted: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let colors = appState.theme.colors
        let showHoverAsset = isHovered || highlighted
        let borderColor = (isHovered || highlighted)
            ? colors.buttonBorderHover
            : colors.sidebarHeaderBorder

        Button(action: action) {
            Group {
                let imageName = showHoverAsset ? hoverName : normalName
                if let nsImage = AppAssets.nsImage(name: imageName) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: ChatMessageChrome.iconSize, height: ChatMessageChrome.iconSize)
                } else {
                    Image(systemName: "questionmark")
                        .font(.system(size: 10))
                }
            }
            .frame(width: ChatMessageChrome.buttonSize, height: ChatMessageChrome.buttonSize)
            .background(isHovered || highlighted ? colors.buttonBgHover : colors.sidebarBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .onHover { isHovered = $0 }
        .graphicButtonTooltip(text: tooltip, icon: tooltipIcon)
    }

    private var tooltipIcon: NSImage? {
        AppAssets.nsImage(name: hoverName) ?? AppAssets.nsImage(name: normalName)
    }
}

struct ChatMessageStopButton: View {
    @Environment(AppState.self) private var appState
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let colors = appState.theme.colors
        let borderColor = isHovered ? colors.buttonBorderHover : colors.sidebarHeaderBorder

        Button(action: action) {
            ChatStopXMark()
                .frame(width: ChatMessageChrome.iconSize, height: ChatMessageChrome.iconSize)
                .frame(width: ChatMessageChrome.buttonSize, height: ChatMessageChrome.buttonSize)
                .background(isHovered ? colors.buttonBgHover : colors.sidebarBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(borderColor, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .graphicButtonTooltip(text: "Stop generation", icon: nil)
    }
}

private struct ChatStopXMark: View {
    var body: some View {
        Canvas { context, size in
            let pad: CGFloat = 2
            var path = Path()
            path.move(to: CGPoint(x: pad, y: pad))
            path.addLine(to: CGPoint(x: size.width - pad, y: size.height - pad))
            path.move(to: CGPoint(x: size.width - pad, y: pad))
            path.addLine(to: CGPoint(x: pad, y: size.height - pad))
            context.stroke(path, with: .color(Color(red: 220 / 255, green: 40 / 255, blue: 40 / 255)), lineWidth: 2)
        }
    }
}
