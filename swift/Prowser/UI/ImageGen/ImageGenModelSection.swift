import SwiftUI

@MainActor
struct ImageGenModelSection: View {
    let plugins: [[String: Any]]
    @Binding var selectedPluginID: String
    let labelWidth: CGFloat
    var onSelectionChanged: (() -> Void)?

    private var selectedPlugin: [String: Any]? {
        plugins.first { ($0["plugin_id"] as? String) == selectedPluginID }
    }

    private var modelNotesLine: String {
        let comment = (selectedPlugin?["model_comment"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !comment.isEmpty else { return "" }
        return "Model Notes: \(comment)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ImageGenInlineFieldLayout.blockSpacing) {
            ImageGenInlineLabeledRow(label: "Model", labelWidth: labelWidth) {
                ImageGenModelSelector(plugins: plugins, selectedPluginID: $selectedPluginID)
                    .onChange(of: selectedPluginID) { _, _ in onSelectionChanged?() }
            }
            if !modelNotesLine.isEmpty {
                ImageGenInlineInfoLine(labelWidth: labelWidth) {
                    Text(modelNotesLine)
                        .font(ImageGenInlineFieldLayout.infoLineFont)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
