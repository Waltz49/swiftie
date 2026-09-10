import SwiftUI

@MainActor
struct LoRASettingsTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("LoRA").font(.title2)

                SettingsSection(title: "Catalog") {
                    SettingsPathRow(
                        title: "LoRA catalog",
                        path: appState.config.dataDirectory.appendingPathComponent("lora_catalog.json").path
                    )
                    Text("LoRA enablement and per-model settings are managed in the image generation dialog and Python settings for full catalog editing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SettingsSection(title: "Image Generation") {
                    HStack {
                        Text("Active LoRA model key")
                        TextField("model key", text: loraModelKeyBinding)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 280)
                    }
                    Button("Open Image Generation Settings…") {
                        appState.openSettingsWindow()
                        NotificationCenter.default.post(
                            name: .prowserOpenSettingsTab,
                            object: nil,
                            userInfo: ["tab": SettingsTab.lora.rawValue]
                        )
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var loraModelKeyBinding: Binding<String> {
        Binding(
            get: {
                let imagegen = appState.config.rawSettings()["imagegen"] as? [String: Any] ?? [:]
                return imagegen["imagegen_lora_model_key"] as? String
                    ?? appState.config.string(forKey: "imagegen_lora_model_key", default: "")
            },
            set: { newValue in
                var imagegen = appState.config.rawSettings()["imagegen"] as? [String: Any] ?? [:]
                imagegen["imagegen_lora_model_key"] = newValue
                appState.config.updateSetting("imagegen", value: imagegen)
                appState.config.updateSetting("imagegen_lora_model_key", value: newValue)
                appState.config.applySettingsChange(emit: appState.eventBus)
            }
        )
    }

}
