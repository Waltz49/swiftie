import SwiftUI

@MainActor
struct ImageGenCreatePanel: View {
    @Binding var values: [String: Any]
    let plugins: [[String: Any]]
    @Binding var selectedPluginID: String

    var body: some View {
        ImageGenPanelShell(
            function: "create",
            values: $values,
            plugins: plugins,
            selectedPluginID: $selectedPluginID
        )
    }
}
