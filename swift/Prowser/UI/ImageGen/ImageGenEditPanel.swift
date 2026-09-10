import SwiftUI

@MainActor
struct ImageGenEditPanel: View {
    @Binding var values: [String: Any]
    let plugins: [[String: Any]]
    @Binding var selectedPluginID: String
    let sourcePaths: [String]

    var body: some View {
        ImageGenPanelShell(
            function: "edit",
            values: $values,
            plugins: plugins,
            selectedPluginID: $selectedPluginID,
            sourcePaths: sourcePaths
        )
    }
}
