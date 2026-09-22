import SwiftUI

@MainActor
struct ExcludesSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var entries: [ExcludeEntry] = []

    struct ExcludeEntry: Identifiable {
        let id = UUID()
        var path: String
        var enabled: Bool
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Excludes").font(.title2)
                Text("Directories excluded from the file tree and scans.")
                    .foregroundStyle(.secondary)

                ForEach($entries) { entry in
                    HStack {
                        SettingsPreferenceSwitch(isOn: entry.enabled)
                        TextField("Path", text: entry.path)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") {
                            let index = entries.firstIndex(where: { $0.id == entry.id })
                            guard let index else { return }
                            SettingsSupport.pickDirectory(into: Binding(
                                get: { entries[index].path.isEmpty ? nil : entries[index].path },
                                set: { entries[index].path = $0 ?? "" ; persist() }
                            ))
                        }
                        Button("Remove") {
                            entries.removeAll { $0.id == entry.id }
                            persist()
                        }
                    }
                }

                Button("Add Exclude Path") {
                    entries.append(ExcludeEntry(path: "", enabled: true))
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { load() }
    }

    private func load() {
        entries = appState.config.excludeDirectories().map { dict in
            ExcludeEntry(
                path: dict["path"] as? String ?? "",
                enabled: dict["enabled"] as? Bool ?? true
            )
        }
    }

    private func persist() {
        let payload = entries
            .filter { !$0.path.isEmpty }
            .map { ["path": $0.path, "enabled": $0.enabled] as [String: Any] }
        appState.config.setExcludeDirectories(payload)
        appState.config.applySettingsChange(emit: appState.eventBus)
    }
}
