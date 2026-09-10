import AppKit
import SwiftUI

struct ClipSearchSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var textPrompt = ""
    @State private var threshold: Double = 0.20
    @State private var useCustomDirectory = false
    @State private var directoryPath = ""
    @State private var recursive = false
    @State private var hideThreshold = false
    @State private var isSearching = false
    @State private var progressText = ""
    @State private var progressValue: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enter text description to search for:")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Text prompt", text: $textPrompt)
                .textFieldStyle(.roundedBorder)

            if !hideThreshold {
                HStack {
                    Text("Similarity threshold:")
                    Slider(value: $threshold, in: 0...1, step: 0.01)
                    Text(String(format: "%.2f", threshold))
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                Text("Images below this score are excluded when filtering.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                        appState.workers.clipSearch.cancel()
                    } else {
                        dismiss()
                    }
                }
                Button(isSearching ? "Stop" : "Search") {
                    if isSearching {
                        appState.workers.clipSearch.cancel()
                    } else {
                        startSearch()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(textPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSearching)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 320)
        .persistedDialogGeometry(
            DialogGeometryKey.clipSearch,
            defaultWidth: 480,
            defaultHeight: 360,
            minWidth: 420,
            minHeight: 300
        )
        .onAppear { loadSavedSettings() }
    }

    @MainActor
    private func loadSavedSettings() {
        let settings = appState.config.rawSettings()
        textPrompt = settings["clip_prompt"] as? String ?? ""
        recursive = settings["clip_recursive"] as? Bool ?? false
        threshold = settings["clip_similarity_threshold"] as? Double
            ?? (settings["clip_similarity_threshold"] as? NSNumber)?.doubleValue
            ?? 0.20

        if let prefill = appState.clipSearchPrefillDirectory {
            useCustomDirectory = true
            directoryPath = prefill
            appState.clipSearchPrefillDirectory = nil
            hideThreshold = !PrsortIO.lockedFilenames(in: prefill).isEmpty
        } else {
            useCustomDirectory = settings["clip_search_dir_enabled"] as? Bool ?? false
            directoryPath = settings["clip_search_dir"] as? String ?? appState.fileData.currentDirectory ?? ""
            if let directory = appState.fileData.currentDirectory {
                hideThreshold = !PrsortIO.lockedFilenames(in: directory).isEmpty
            }
        }
        if hideThreshold {
            threshold = 0
        }
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
            hideThreshold = !PrsortIO.lockedFilenames(in: url.path).isEmpty
            if hideThreshold { threshold = 0 }
        }
    }

    @MainActor
    private func startSearch() {
        let prompt = textPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        let effectiveThreshold = hideThreshold ? 0.0 : threshold
        appState.config.updateSetting("clip_prompt", value: prompt)
        appState.config.updateSetting("clip_recursive", value: recursive)
        if !hideThreshold {
            appState.config.updateSetting("clip_similarity_threshold", value: effectiveThreshold)
        }
        appState.config.updateSetting("clip_search_dir_enabled", value: useCustomDirectory)
        appState.config.updateSetting("clip_search_dir", value: directoryPath)

        let searchDirectory: String?
        if useCustomDirectory,
           !directoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchDirectory = (directoryPath as NSString).expandingTildeInPath
        } else {
            searchDirectory = nil
        }

        isSearching = true
        progressText = "Starting CLIP search…"
        progressValue = 0

        Task { @MainActor in
            do {
                let paths = try await appState.searchOperations.runClipSearch(
                    text: prompt,
                    threshold: effectiveThreshold,
                    recursive: recursive,
                    directory: searchDirectory,
                    onProgress: { current, total, stage in
                        if total > 0 {
                            progressValue = Double(current) / Double(total)
                        }
                        progressText = stageLabel(stage, current: current, total: total)
                    }
                )
                isSearching = false
                dismiss()
                appState.searchOperations.applyClipSearchResults(paths, prompt: prompt)
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

    private func stageLabel(_ stage: String, current: Int, total: Int) -> String {
        switch stage {
        case "loading_model":
            return "Loading CLIP model…"
        default:
            if stage.isEmpty {
                return total > 0 ? "Processing \(current)/\(total)…" : "Searching…"
            }
            return stage.replacingOccurrences(of: "_", with: " ")
        }
    }
}
