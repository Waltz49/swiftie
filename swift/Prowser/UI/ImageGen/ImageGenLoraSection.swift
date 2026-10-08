import SwiftUI

@MainActor
struct ImageGenLoraSection: View {
    @Environment(AppState.self) private var appState
    @Binding var values: [String: Any]
    let plugin: [String: Any]
    var onValuesChanged: (() -> Void)?

    private var supportsLora: Bool {
        let host = plugin["lora_host_id"] as? String ?? ""
        return !host.isEmpty
    }

    private var headingText: String {
        let host = plugin["lora_host_id"] as? String ?? ""
        return host == "sd15" ? "LoRA" : "LoRAs"
    }

    private var pluginID: String {
        plugin["plugin_id"] as? String ?? ""
    }

    private var hasSelection: Bool {
        if let stack = values["mflux_lora_stack"] as? [String], !stack.isEmpty { return true }
        if let single = values["mflux_lora"] as? String, single != "none", !single.isEmpty { return true }
        return false
    }

    @State private var loraSelectionDetail = ""

    var body: some View {
        if supportsLora {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 4) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(headingText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ImageGenLoraPicker(
                            pluginID: pluginID,
                            values: $values,
                            selectionDetailLine: $loraSelectionDetail,
                            onValuesChanged: onValuesChanged
                        )
                    }
                    ImageGenSettingsGearButton(
                        settingsTab: .lora,
                        tooltip: "LoRA settings",
                        loraModelKey: loraModelKeyForPlugin()
                    )
                    ImageGenLoraClearButton(isVisible: hasSelection) {
                        clearLoras()
                    }
                }
                Text(loraSelectionDetail.isEmpty ? " " : loraSelectionDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(
                        loraSelectionDetail.isEmpty ? "No LoRAs selected" : loraSelectionDetail
                    )
            }
        }
    }

    private func loraModelKeyForPlugin() -> String? {
        if let descriptor = ImageGenPluginCatalog.plugin(pluginID: pluginID) {
            return descriptor.hfModelID.isEmpty ? nil : descriptor.hfModelID
        }
        return plugin["hf_model_id"] as? String
    }

    private func clearLoras() {
        values.removeValue(forKey: "mflux_lora")
        values.removeValue(forKey: "mflux_lora_stack")
        values.removeValue(forKey: "mflux_lora_scales_by_id")
        values["mflux_lora_stack"] = []
        onValuesChanged?()
    }
}
