import AppKit
import SwiftUI

struct ClipSearchOptions: Sendable {
    var prompt: String
    var recursive: Bool
    var useCustomDirectory: Bool
    var customDirectory: String
    var threshold: Double
}

@MainActor
struct ClipSearchSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.closeDialog) private var closeDialog
    let onSubmit: (ClipSearchOptions) -> Void

    @State private var prompt = ""
    @State private var recursive = false
    @State private var useCustomDirectory = false
    @State private var customDirectory = ""
    @State private var threshold = 0.20

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Search images by text description:")
            TextField("Enter search text", text: $prompt)
                .textFieldStyle(.roundedBorder)
            HStack {
                Text("Minimum similarity")
                Slider(value: $threshold, in: 0 ... 1)
                Text(String(format: "%.2f", threshold))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            HStack(spacing: 8) {
                Toggle("", isOn: $useCustomDirectory)
                    .labelsHidden()
                    .frame(width: 24)
                TextField("Directory for search", text: $customDirectory)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!useCustomDirectory)
                Button("…") { browseDirectory() }
                    .disabled(!useCustomDirectory)
            }
            Toggle("Search in subdirectories", isOn: $recursive)
                .padding(.leading, 28)
                .disabled(!useCustomDirectory)
            HStack {
                Spacer()
                Button("Cancel") { closeDialog() }
                    .keyboardShortcut(.cancelAction)
                Button("Search") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 460)
        .onAppear { loadDefaults() }
        .onChange(of: useCustomDirectory) { _, enabled in
            if enabled {
                recursive = appState.config.bool(forKey: "clip_recursive", default: false)
            } else {
                recursive = false
            }
        }
    }

    private func loadDefaults() {
        prompt = appState.config.string(forKey: "clip_prompt", default: "")
        recursive = appState.config.bool(forKey: "clip_recursive", default: false)
        useCustomDirectory = appState.config.bool(forKey: "clip_search_dir_enabled", default: false)
        customDirectory = appState.config.string(forKey: "clip_search_dir", default: "")
        threshold = appState.config.double(forKey: "clip_similarity_threshold", default: 0.20)
        if customDirectory.isEmpty, let dir = SearchImagePathCollector.currentSearchDirectory(appState: appState) {
            customDirectory = dir
        }
        if !useCustomDirectory {
            recursive = false
        }
    }

    private func browseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            customDirectory = url.path
        }
    }

    private func submit() {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appState.config.updateSetting("clip_prompt", value: trimmed)
        let effectiveRecursive = useCustomDirectory && recursive
        appState.config.updateSetting("clip_recursive", value: effectiveRecursive)
        appState.config.updateSetting("clip_search_dir_enabled", value: useCustomDirectory)
        appState.config.updateSetting("clip_search_dir", value: customDirectory.trimmingCharacters(in: .whitespacesAndNewlines))
        appState.config.updateSetting("clip_similarity_threshold", value: threshold)
        closeDialog()
        onSubmit(ClipSearchOptions(
            prompt: trimmed,
            recursive: effectiveRecursive,
            useCustomDirectory: useCustomDirectory,
            customDirectory: customDirectory.trimmingCharacters(in: .whitespacesAndNewlines),
            threshold: threshold
        ))
    }
}
