import SwiftUI

/// LoRA field heading with gear settings and clear buttons (Python `mount_image_gen_lora_field`).
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

    private var pluginID: String {
        plugin["plugin_id"] as? String ?? ""
    }

    private var isStackMode: Bool {
        let host = plugin["lora_host_id"] as? String ?? ""
        return host != "sd15"
    }

    private var hasSelection: Bool {
        if let stack = values["mflux_lora_stack"] as? [Any], !stack.isEmpty {
            return true
        }
        let preset = values["mflux_lora"] as? String ?? "none"
        return !preset.isEmpty && preset != "none"
    }

    private var headingText: String {
        isStackMode ? "LoRAs" : "LoRA"
    }

    var body: some View {
        if supportsLora {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(headingText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    ImageGenSettingsGearButton(
                        settingsTab: .lora,
                        tooltip: "Open LoRA settings",
                        loraModelKey: plugin["hf_model_id"] as? String
                    )
                    ImageGenLoraClearButton(isVisible: hasSelection, action: clearLoras)
                }
                ImageGenLoraPicker(
                    pluginID: pluginID,
                    values: $values,
                    onValuesChanged: onValuesChanged
                )
                .help("Optional style add-on for this model.\nSome styles need a trigger word\nwithin your prompt.")
            }
        }
    }

    private func clearLoras() {
        values["mflux_lora"] = "none"
        values["mflux_lora_stack"] = []
        values["mflux_lora_scales_by_id"] = [:]
        onValuesChanged?()
        appState.status.show("LoRA selection cleared.")
    }
}
