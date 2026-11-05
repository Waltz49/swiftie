import SwiftUI

struct CheckLorasResultsSheetView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.closeDialog) private var closeDialog
    let bodyText: String
    var cancelledBanner: String?

    private var fullCopyText: String {
        var parts: [String] = []
        if let cancelledBanner, !cancelledBanner.isEmpty {
            parts.append(cancelledBanner)
        }
        parts.append(bodyText)
        return parts.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Test LoRAs results:")
                .foregroundStyle(.secondary)
            if let cancelledBanner, !cancelledBanner.isEmpty {
                Text(cancelledBanner)
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            ScrollView {
                Text(bodyText)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 360)
            DialogButtonRow(
                [
                    DialogButton("OK", isDefault: true, isCancel: true) { closeDialog() },
                ],
                leadingButtons: [
                    DialogButton("Copy", id: "copy") {
                        appState.copyTextToClipboard(fullCopyText)
                    },
                ],
                focusDefaultOnAppear: true
            )
        }
        .padding(20)
        .themeDialogStyle()
        .persistedDialogGeometry(
            DialogGeometryKey.checkLorasResults,
            defaultWidth: 640,
            defaultHeight: 520,
            minWidth: 520,
            minHeight: 400
        )
    }
}
