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
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Toggle("", isOn: $useCustomDirectory)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .frame(width: SearchSheetCheckboxLayout.width)
                    TextField("Directory for search", text: $customDirectory)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!useCustomDirectory)
                    Button("…") { browseDirectory() }
                        .disabled(!useCustomDirectory)
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Toggle("", isOn: $recursive)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .frame(width: SearchSheetCheckboxLayout.width)
                        .disabled(!useCustomDirectory)
                    Text("Search in subdirectories")
                        .foregroundStyle(useCustomDirectory ? Color.primary : Color.secondary)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard useCustomDirectory else { return }
                            recursive.toggle()
                        }
                }
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
        .onChange(of: useCustomDirectory) { _, enabled in
            if enabled {
                recursive = appState.config.bool(forKey: "cnn_recursive", default: false)
            } else {
                recursive = false
            }
            validateDirectory()
        }
    }

    private func loadDefaults() {
        recursive = appState.config.bool(forKey: "cnn_recursive", default: false)
        if let prime = appState.consumeSimilaritySearchDirectoryPrime() {
            useCustomDirectory = prime.useCustomDirectory
            customDirectory = prime.customDirectory
            if useCustomDirectory {
                recursive = appState.config.bool(forKey: "cnn_recursive", default: false)
            }
        } else {
            useCustomDirectory = appState.config.bool(forKey: "cnn_search_dir_enabled", default: false)
            customDirectory = appState.config.string(forKey: "cnn_search_dir", default: "")
        }
        if customDirectory.isEmpty, let dir = SearchImagePathCollector.currentSearchDirectory(appState: appState) {
            customDirectory = dir
        }
        if !useCustomDirectory {
            recursive = false
        }
        validateDirectory()
    }

    private func validateDirectory() {
        let path = AppState.expandedSearchDirectoryPath(customDirectory)
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
        let effectiveRecursive = useCustomDirectory && recursive
        let expandedDir = AppState.expandedSearchDirectoryPath(customDirectory)
        appState.config.updateSetting("cnn_recursive", value: effectiveRecursive)
        appState.config.updateSetting("cnn_search_dir_enabled", value: useCustomDirectory)
        appState.config.updateSetting("cnn_search_dir", value: expandedDir)
        let options = SimilaritySearchOptions(
            recursive: effectiveRecursive,
            useCustomDirectory: useCustomDirectory,
            customDirectory: expandedDir
        )
        closeDialog()
        onSubmit(options)
    }
}
