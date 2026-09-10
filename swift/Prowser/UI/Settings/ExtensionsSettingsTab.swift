import SwiftUI

@MainActor
struct ExtensionsSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var enabledExtensions: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("File Types").font(.title2)
                Text("Select which extensions are recognized as images.")
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), alignment: .leading)], alignment: .leading) {
                    ForEach(ThemeDefaults.knownExtensionList, id: \.self) { ext in
                        Toggle(ext, isOn: Binding(
                            get: { enabledExtensions.contains(ext) },
                            set: { on in
                                if on { enabledExtensions.insert(ext) } else { enabledExtensions.remove(ext) }
                                persist()
                            }
                        ))
                    }
                }

                Text("Only enable extensions you need; large lists can affect performance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            enabledExtensions = Set(appState.config.imageExtensions)
        }
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
