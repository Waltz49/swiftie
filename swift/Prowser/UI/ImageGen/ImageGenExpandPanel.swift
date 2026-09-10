import SwiftUI

@MainActor
struct ImageGenExpandPanel: View {
    @Binding var values: [String: Any]
    let plugins: [[String: Any]]
    @Binding var selectedPluginID: String
    let sourcePath: String?

    var body: some View {
        ImageGenPanelShell(
            function: "expand",
            values: $values,
            plugins: plugins,
            selectedPluginID: $selectedPluginID,
            sourcePath: sourcePath
        )
    }
}
