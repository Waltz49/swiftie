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

    private var hasSelection: Bool {
        if let stack = values["mflux_lora_stack"] as? [Any], !stack.isEmpty {
            return true
        }
        let preset = values["mflux_lora"] as? String ?? "none"
        return !preset.isEmpty && preset != "none"
    }

    private var summaryText: String {
        if let stack = values["mflux_lora_stack"] as? [Any], !stack.isEmpty {
            let labels = stack.compactMap { item -> String? in
                if let string = item as? String { return string }
                return nil
            }
            if labels.isEmpty { return "\(stack.count) selected" }
            return labels.joined(separator: " + ")
        }
        let preset = values["mflux_lora"] as? String ?? "none"
        if preset.isEmpty || preset == "none" { return "None" }
        return preset
    }

    var body: some View {
        if supportsLora {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("LoRA")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    ImageGenSettingsGearButton(
                        settingsTab: .lora,
                        tooltip: "Open LoRA settings"
                    )
                    ImageGenLoraClearButton(isVisible: hasSelection, action: clearLoras)
                }
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .help("Optional style add-on for this model.\nSome styles need a trigger word\nwithin your prompt.")
            }
        }
    }

    private func clearLoras() {
        values["mflux_lora"] = "none"
        values["mflux_lora_stack"] = []
        onValuesChanged?()
        appState.status.show("LoRA selection cleared.")
    }
}
