import SwiftUI

struct DownloadingModelsHelpView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeDialog) private var closeDialog
    @Environment(\.themeColors) private var colors
    @Environment(AppState.self) private var appState

    @State private var expandedSectionIDs: Set<String> = []
    @State private var scriptContext: DownloadingModelsHelpHTML.ScriptContext?

    private var pageHTML: String {
        guard let scriptContext else {
            return "<html><body></body></html>"
        }
        return DownloadingModelsHelpHTML.build(
            expanded: expandedSectionIDs,
            colors: colors,
            context: scriptContext
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Downloading AI Models")
                .font(.system(.title2, design: .default))
                .frame(maxWidth: .infinity, alignment: .center)

            HelpInteractiveHTMLWebView(
                html: pageHTML,
                onToggle: { sectionID in
                    if expandedSectionIDs.contains(sectionID) {
                        expandedSectionIDs.remove(sectionID)
                    } else {
                        expandedSectionIDs.insert(sectionID)
                    }
                },
                onCopy: { blockID in
                    guard let text = scriptContext?.scriptsByID[blockID], !text.isEmpty else { return }
                    appState.copyTextToClipboard(text)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            DialogButtonRow([
                DialogButton("Close", isDefault: true, isCancel: true) { closeDialog(); dismiss() },
            ], focusDefaultOnAppear: true)
        }
        .padding(24)
        .frame(minWidth: 640, minHeight: 480)
        .themeDialogStyle()
        .persistedDialogGeometry(
            DialogGeometryKey.downloadingModelsHelp,
            defaultWidth: 920,
            defaultHeight: 720,
            minWidth: 640,
            minHeight: 480
        )
        .onAppear {
            if scriptContext == nil {
                scriptContext = DownloadingModelsHelpHTML.makeScriptContext(
                    imagegenPythonPath: appState.config.imagegenVenvPythonPath()
                )
            }
        }
    }
}