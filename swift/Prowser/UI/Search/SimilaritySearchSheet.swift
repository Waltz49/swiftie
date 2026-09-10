import AppKit
import SwiftUI

struct SimilaritySearchOptions: Equatable {
    var useCustomDirectory: Bool
    var directoryPath: String
    var recursive: Bool
}

struct SimilaritySearchSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var useCustomDirectory = false
    @State private var directoryPath = ""
    @State private var recursive = false
    @State private var isSearching = false
    @State private var progressText = ""
    @State private var progressValue: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Find images similar to the selected image(s):")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            if let directory = appState.fileData.currentDirectory {
                Text(directoryLabel(directory))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack(spacing: 8) {
                Toggle("", isOn: $useCustomDirectory)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .frame(width: 20)
                TextField("Directory path for search", text: $directoryPath)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!useCustomDirectory)
                Button("…") { browseDirectory() }
                    .disabled(!useCustomDirectory)
            }

            Toggle("Search subdirectories recursively", isOn: $recursive)

            if isSearching {
                ProgressView(value: progressValue, total: 1.0)
                Text(progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    if isSearching {
                        appState.workers.similaritySearch.cancel()
                    } else {
                        dismiss()
                    }
                }
                Button(isSearching ? "Stop" : "Search") {
                    if isSearching {
                        appState.workers.similaritySearch.cancel()
                    } else {
                        startSearch()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSearching && progressText.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 260)
        .persistedDialogGeometry(
            DialogGeometryKey.similaritySearch,
            defaultWidth: 480,
            defaultHeight: 280,
            minWidth: 420,
            minHeight: 240
        )
        .onAppear { loadSavedSettings() }
    }

    @MainActor
    private func loadSavedSettings() {
        let settings = appState.config.rawSettings()
        useCustomDirectory = settings["cnn_search_dir_enabled"] as? Bool ?? false
        directoryPath = settings["cnn_search_dir"] as? String ?? appState.fileData.currentDirectory ?? ""
        recursive = settings["cnn_recursive"] as? Bool ?? false
    }

    @MainActor
    private func browseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        let start = directoryPath.isEmpty ? appState.fileData.currentDirectory : directoryPath
        if let start, !start.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: start)
        }
        if panel.runModal() == .OK, let url = panel.url {
            directoryPath = url.path
        }
    }

    @MainActor
    private func startSearch() {
        appState.config.updateSetting("cnn_recursive", value: recursive)
        appState.config.updateSetting("cnn_search_dir_enabled", value: useCustomDirectory)
        appState.config.updateSetting("cnn_search_dir", value: directoryPath)

        let options = SimilaritySearchOptions(
            useCustomDirectory: useCustomDirectory,
            directoryPath: directoryPath,
            recursive: recursive
        )

        isSearching = true
        progressText = "Starting similarity search…"
        progressValue = 0

        Task { @MainActor in
            do {
                let paths = try await appState.searchOperations.runSimilaritySearch(options: options) { current, total, stage in
                    if total > 0 {
                        progressValue = Double(current) / Double(total)
                    }
                    if stage.isEmpty {
                        progressText = "Processing \(current)/\(total)…"
                    } else {
                        progressText = stage.replacingOccurrences(of: "_", with: " ")
                    }
                }
                isSearching = false
                dismiss()
                appState.searchOperations.applySimilarityResults(paths)
            } catch is CancellationError {
                isSearching = false
                dismiss()
            } catch {
                isSearching = false
                appState.status.show(error.localizedDescription)
                dismiss()
            }
        }
    }

    private func directoryLabel(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix(NSHomeDirectory()) {
            return "~" + String(expanded.dropFirst(NSHomeDirectory().count))
        }
        return expanded
    }
}
