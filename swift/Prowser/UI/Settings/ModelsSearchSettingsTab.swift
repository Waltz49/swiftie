import SwiftUI

@MainActor
struct ModelsSearchSettingsTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Models for Search").font(.title2)

                SettingsSection(title: "Similarity Search") {
                    Picker("Metric", selection: stringBinding("similarity_metric", default: "cosine")) {
                        Text("Cosine").tag("cosine")
                        Text("Euclidean").tag("euclidean")
                        Text("Manhattan").tag("manhattan")
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)

                    Picker("ResNet model", selection: stringBinding("resnet_model", default: "resnet18")) {
                        Text("ResNet18 (fastest)").tag("resnet18")
                        Text("ResNet50 (balanced)").tag("resnet50")
                        Text("ResNet101 (best quality)").tag("resnet101")
                    }
                    .pickerStyle(.radioGroup)
                }

                SettingsSection(title: "CLIP Text Search") {
                    Picker("CLIP model", selection: stringBinding(
                        "clip_model_name",
                        default: "openai/clip-vit-base-patch32"
                    )) {
                        Text("openai/clip-vit-base-patch32").tag("openai/clip-vit-base-patch32")
                        Text("openai/clip-vit-large-patch14").tag("openai/clip-vit-large-patch14")
                    }
                    .pickerStyle(.radioGroup)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func stringBinding(_ key: String, default defaultValue: String) -> Binding<String> {
        SettingsSupport.stringBinding(config: appState.config, key: key, default: defaultValue, onChange: settingsChanged)
    }

    private func settingsChanged() {
        appState.config.applySettingsChange(emit: appState.eventBus)
        appState.workers.reloadSettings(config: appState.config)
    }
}
