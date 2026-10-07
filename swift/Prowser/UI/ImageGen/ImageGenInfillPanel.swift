import SwiftUI

@MainActor
struct ImageGenInfillPanel: View {
    @Binding var values: [String: Any]
    let plugins: [[String: Any]]
    @Binding var selectedPluginID: String
    let sourcePath: String?

    var body: some View {
        ImageGenPanelShell(
            function: "infill",
            values: $values,
            plugins: plugins,
            selectedPluginID: $selectedPluginID,
            sourcePath: sourcePath
        )
    }
}
