import SwiftUI

struct CheckLorasResultsSheetView: View {
    @Environment(\.closeDialog) private var closeDialog
    let bodyText: String
    var cancelledBanner: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Changes from this Check LoRAs run:")
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
            DialogButtonRow([
                DialogButton("OK", isDefault: true, isCancel: true) { closeDialog() },
            ])
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
