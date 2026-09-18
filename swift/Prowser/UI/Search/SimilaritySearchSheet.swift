import AppKit
import SwiftUI

struct SimilaritySearchOptions: Sendable {
    var recursive: Bool
    var useCustomDirectory: Bool
    var customDirectory: String
}

@MainActor
struct SimilaritySearchSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.closeDialog) private var closeDialog
    let onSubmit: (SimilaritySearchOptions) -> Void

    @State private var recursive = false
    @State private var useCustomDirectory = false
    @State private var customDirectory = ""
    @State private var dirValid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Find images similar to the selected image(s):")
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Search in subdirectories", isOn: $recursive)
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
            HStack {
                Spacer()
                Button("Cancel") { closeDialog() }
                    .keyboardShortcut(.cancelAction)
                Button("Search") { submit() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 440)
        .onAppear { loadDefaults() }
        .onChange(of: customDirectory) { _, _ in validateDirectory() }
        .onChange(of: useCustomDirectory) { _, _ in validateDirectory() }
    }

    private func loadDefaults() {
        recursive = appState.config.bool(forKey: "cnn_recursive", default: false)
        useCustomDirectory = appState.config.bool(forKey: "cnn_search_dir_enabled", default: false)
        customDirectory = appState.config.string(forKey: "cnn_search_dir", default: "")
        if customDirectory.isEmpty, let dir = SearchImagePathCollector.currentSearchDirectory(appState: appState) {
            customDirectory = dir
        }
        validateDirectory()
    }

    private func validateDirectory() {
        let path = customDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        dirValid = !useCustomDirectory || FileManager.default.fileExists(atPath: path)
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
        appState.config.updateSetting("cnn_recursive", value: recursive)
        appState.config.updateSetting("cnn_search_dir_enabled", value: useCustomDirectory)
        appState.config.updateSetting("cnn_search_dir", value: customDirectory.trimmingCharacters(in: .whitespacesAndNewlines))
        let options = SimilaritySearchOptions(
            recursive: recursive,
            useCustomDirectory: useCustomDirectory,
            customDirectory: customDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        closeDialog()
        onSubmit(options)
    }
}
