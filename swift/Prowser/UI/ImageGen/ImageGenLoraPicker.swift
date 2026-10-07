import SwiftUI

extension Notification.Name {
    static let prowserLoraCatalogChanged = Notification.Name("prowser.loraCatalogChanged")
    static let prowserSelectLoraSettingsModel = Notification.Name("prowser.selectLoraSettingsModel")
}

/// LoRA selection stub (management not implemented on WithGen yet).
@MainActor
struct ImageGenLoraPicker: View {
    @Environment(AppState.self) private var appState
    let pluginID: String
    @Binding var values: [String: Any]
    var onValuesChanged: (() -> Void)?

    private static let stubLabel = "Not implemented yet"

    var body: some View {
        Picker("LoRA", selection: .constant(Self.stubLabel)) {
            Text(Self.stubLabel).tag(Self.stubLabel)
        }
        .labelsHidden()
        .disabled(true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
