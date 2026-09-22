import SwiftUI

@MainActor
struct ExtensionsSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var enabledExtensions: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("File Types").font(.title2)

                SettingsOutlinedGroupBox(title: { settingsOutlinedGroupBoxTitle("Image File Extensions") }) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Select which file extensions should be recognized as image files.")
                            .font(.system(size: 11))
                            .foregroundStyle(SettingsDialogChrome.secondaryText)
                            .padding(.horizontal, 8)

                        extensionToggleGrid
                    }
                }

                Text("Adding many extensions may affect performance. Only enable extensions you need to access.")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsDialogChrome.secondaryText)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            reloadFromConfig()
        }
        .onChange(of: appState.settingsOpenRequestToken) { _, _ in
            reloadFromConfig()
        }
    }

    @ViewBuilder
    private var extensionToggleGrid: some View {
        let extensions = ThemeDefaults.knownExtensionList
        let columns = SettingsColumnMajorGrid.columns(
            items: extensions,
            columnCount: SettingsColumnMajorGrid.columnCount(itemCount: extensions.count, preferredColumns: 3)
        )
        SettingsPreferenceCompactToggleColumnGrid(
            columns: columns,
            columnRowTitles: { $0 }
        ) { ext in
            SettingsPreferenceCompactToggleRow(
                title: ext,
                tooltip: "Recognize \(ext) files as images",
                isOn: Binding(
                    get: { enabledExtensions.contains(ext) },
                    set: { on in
                        if on { enabledExtensions.insert(ext) } else { enabledExtensions.remove(ext) }
                        persist()
                    }
                )
            )
        }
    }

    private func reloadFromConfig() {
        enabledExtensions = Set(appState.config.imageExtensions)
    }

    private func persist() {
        let sorted = ThemeDefaults.knownExtensionList.filter { enabledExtensions.contains($0) }
        let stored = sorted.map { ".\($0)" }
        appState.config.setValue(stored, forKey: "image_extensions")
        appState.config.applySettingsChange(emit: appState.eventBus)
        if let dir = appState.fileData.currentDirectory {
            appState.loadDirectory(dir, saveHistory: false)
        }
    }
}
