import SwiftUI

@MainActor
struct ThemeSettingsTab: View {
    @Environment(AppState.self) private var appState

    private let editableThemes = ["dark", "light", "user"]
    private let colorKeys: [(String, String)] = [
        ("Application background", "default_background_color_hex"),
        ("Main text", "text_color_hex"),
        ("Thumbnail grid background", "thumbnail_grid_background_color_hex"),
        ("Sidebar background", "sidebar_background_color_hex"),
        ("Sidebar text", "sidebar_text_color_hex"),
        ("Current image border", "current_image_border_color_hex"),
        ("Current image background", "current_image_background_color_hex"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Theme").font(.title2)

                SettingsSection(title: "Preset") {
                    Picker("Active theme", selection: themeBinding) {
                        Text("Dark").tag("dark")
                        Text("Light").tag("light")
                        Text("User").tag("user")
                        Text("System").tag("system")
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 420)
                }

                if editableThemes.contains(appState.theme.themeID) || editableThemes.contains(appState.theme.resolvedThemeID) {
                    let editID = editableThemes.contains(appState.theme.themeID)
                        ? appState.theme.themeID
                        : appState.theme.resolvedThemeID

                    SettingsSection(title: "Colors (\(editID))") {
                        ForEach(colorKeys, id: \.1) { label, key in
                            ThemeColorRow(
                                label: label,
                                hex: colorHex(editID, key: key),
                                onPick: { newHex in
                                    appState.theme.setColorOverride(themeID: editID, key: key, hex: newHex)
                                    appState.config.applySettingsChange(emit: appState.eventBus)
                                }
                            )
                        }
                        Button("Reset Colors to Defaults") {
                            appState.theme.resetColorOverrides(for: editID)
                            appState.config.applySettingsChange(emit: appState.eventBus)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var themeBinding: Binding<String> {
        Binding(
            get: { appState.theme.themeID },
            set: { newValue in
                appState.theme.setThemeID(newValue)
                appState.config.applySettingsChange(emit: appState.eventBus)
            }
        )
    }

    private func colorHex(_ themeID: String, key: String) -> String {
        appState.theme.colorOverrides(for: themeID)[key] as? String ?? ""
    }
}

private struct ThemeColorRow: View {
    let label: String
    let hex: String
    let onPick: (String) -> Void

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hex: hex) ?? .gray)
                .frame(width: 28, height: 20)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary))
            TextField("Hex", text: Binding(
                get: { hex },
                set: { onPick($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 100)
        }
    }
}
