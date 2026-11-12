import SwiftUI

/// Toolbar copy control using bundled `copy` / `copy_hover` assets (Python copy_feedback parity).
@MainActor
struct ClipboardCopyIconButton: View {
    @Environment(AppState.self) private var appState

    let text: String
    var size: CGFloat = ImageGenChrome.fieldButtonSize
    var iconSize: CGFloat? = nil
    var tooltip: String = "Copy to clipboard"
    let action: (() -> Void)?

    init(
        text: String,
        size: CGFloat = ImageGenChrome.fieldButtonSize,
        iconSize: CGFloat? = nil,
        tooltip: String = "Copy to clipboard",
        action: (() -> Void)? = nil
    ) {
        self.text = text
        self.size = size
        self.iconSize = iconSize
        self.tooltip = tooltip
        self.action = action
    }

    var body: some View {
        AppAssetIconButton(
            normalName: "copy",
            hoverName: "copy_hover",
            size: size,
            iconSize: iconSize,
            tooltip: tooltip,
            action: performCopy
        )
    }

    private func performCopy() {
        if let action {
            action()
        } else {
            appState.copyTextToClipboard(text, hostWindow: appState.copyFeedbackHostWindow())
        }
    }
}
