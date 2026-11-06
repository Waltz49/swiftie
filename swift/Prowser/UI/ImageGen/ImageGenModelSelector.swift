import SwiftUI

@MainActor
struct ImageGenModelSelector: View {
    @Environment(\.imageGenControlsInSplitPane) private var inSplitPane
    let plugins: [[String: Any]]
    @Binding var selectedPluginID: String

    var body: some View {
        Picker("", selection: $selectedPluginID) {
            ForEach(plugins.indices, id: \.self) { index in
                let plugin = plugins[index]
                let id = plugin["plugin_id"] as? String ?? ""
                let label = plugin["model_label"] as? String ?? plugin["display_name"] as? String ?? id
                let available = plugin["available"] as? Bool ?? true
                Text(available ? label : "\(label) (unavailable)")
                    .tag(id)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityLabel("Model")
        .frame(
            minWidth: inSplitPane ? 0 : ImageGenInlineFieldLayout.fieldControlMinWidth,
            maxWidth: inSplitPane ? .infinity : ImageGenInlineFieldLayout.fieldControlMaxWidth,
            alignment: .leading
        )
    }
}
