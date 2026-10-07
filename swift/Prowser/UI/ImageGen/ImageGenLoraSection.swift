import SwiftUI

/// LoRA field heading (stub — no catalog or settings gear).
@MainActor
struct ImageGenLoraSection: View {
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

    var body: some View {
        if supportsLora {
            VStack(alignment: .leading, spacing: 4) {
                Text(headingText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ImageGenLoraPicker(
                    pluginID: plugin["plugin_id"] as? String ?? "",
                    values: $values,
                    onValuesChanged: onValuesChanged
                )
            }
        }
    }
}
