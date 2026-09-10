import SwiftUI

@MainActor
struct MapsEditorSettingsTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Maps and Editor").font(.title2)

                SettingsSection(title: "Map Application") {
                    Picker("Open GPS locations in", selection: mapAppBinding) {
                        Text("Apple Maps").tag("apple_maps")
                        Text("Google Maps").tag("google_maps")
                        Text("Google Earth").tag("google_earth")
                    }
                    .pickerStyle(.radioGroup)
                }

                SettingsSection(title: "External Image Editor") {
                    HStack {
                        Text("Editor application")
                        Spacer()
                        Text(appState.config.string(forKey: "image_editor_app", default: "Preview"))
                            .foregroundStyle(.secondary)
                    }
                    TextField("Application name", text: editorBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                    Text("Used for Edit in … context menu and ⌃E.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var mapAppBinding: Binding<String> {
        SettingsSupport.stringBinding(
            config: appState.config,
            key: "map_application",
            default: "apple_maps",
            onChange: settingsChanged
        )
    }

    private var editorBinding: Binding<String> {
        SettingsSupport.stringBinding(
            config: appState.config,
            key: "image_editor_app",
            default: "Preview",
            onChange: settingsChanged
        )
    }

    private func settingsChanged() {
        appState.config.applySettingsChange(emit: appState.eventBus)
    }
}
