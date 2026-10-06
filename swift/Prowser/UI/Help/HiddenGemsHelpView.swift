import SwiftUI

struct HiddenGemsHelpView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeDialog) private var closeDialog
    @Environment(\.themeColors) private var colors

    private var pageHTML: String {
        HelpMarkdownHTML.themedPage(markdown: HiddenGemsHelpContent.markdown(), colors: colors)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AboutHTMLWebView(html: pageHTML)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            DialogButtonRow([
                DialogButton("Close", isDefault: true, isCancel: true) { closeDialog(); dismiss() },
            ], focusDefaultOnAppear: true)
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 520)
        .themeDialogStyle()
        .persistedDialogGeometry(
            DialogGeometryKey.hiddenGemsHelp,
            defaultWidth: 520,
            defaultHeight: 560,
            minWidth: 480,
            minHeight: 400
        )
    }
}
