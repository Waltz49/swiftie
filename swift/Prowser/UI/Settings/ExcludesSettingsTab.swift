import SwiftUI

@MainActor
struct ExcludesSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var entries: [ExcludeEntry] = (0..<9).map { _ in
        ExcludeEntry(enabled: false, path: "")
    }

    private static let slotCount = 9

    struct ExcludeEntry: Identifiable {
        let id = UUID()
        var enabled: Bool
        var path: String
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Exclude Directories").font(.title2)
                Text("Used to exclude files in specific directories from the thumbnail view when pressing ⌘X.")
                    .foregroundStyle(.secondary)

                ForEach(0..<Self.slotCount, id: \.self) { index in
                    HStack {
                        SettingsPreferenceSwitch(isOn: enabledBinding(index))
                            .help("Enable this exclude rule when pressing ⌘X")
                        SettingsPathTextField(
                            title: "Path",
                            text: pathBinding(index),
                            prompt: Text("Enter string to exclude"),
                            help:
                                "Path substring or folder name to exclude from thumbnail view (⌘X).\nUse Choose… to pick a directory."
                        )
                        SettingsPathValidationIndicator(
                            state: SettingsPathValidation.validateDirectoryPath(entries[index].path)
                        )
                        Button("Choose…") {
                            SettingsSupport.pickDirectory(into: Binding(
                                get: { entries[index].path.isEmpty ? nil : entries[index].path },
                                set: { entries[index].path = $0 ?? ""; persist() }
                            ))
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { load() }
    }

    private func enabledBinding(_ index: Int) -> Binding<Bool> {
        Binding(
            get: { entries[index].enabled },
            set: { entries[index].enabled = $0; persist() }
        )
    }

    private func pathBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { entries[index].path },
            set: { entries[index].path = $0; persist() }
        )
    }

    private func load() {
        let stored = appState.config.excludeDirectories()
        entries = (0..<Self.slotCount).map { index in
            let dict = index < stored.count ? stored[index] : [:]
            let enabled = dict["enabled"] as? Bool ?? false
            if let path = dict["path"] as? String, !path.isEmpty {
                return ExcludeEntry(
                    enabled: enabled,
                    path: SettingsPathValidation.displayPath(path)
                )
            }
            return ExcludeEntry(enabled: enabled, path: "")
        }
    }

    private func persist() {
        let payload: [[String: Any]] = entries.map { entry in
            let trimmed = entry.path.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return ["path": NSNull(), "enabled": false] as [String: Any]
            }
            return [
                "path": SettingsPathValidation.expandedPath(trimmed),
                "enabled": entry.enabled,
            ] as [String: Any]
        }
        appState.config.setExcludeDirectories(payload)
        appState.config.applySettingsChange(emit: appState.eventBus)
    }
}
