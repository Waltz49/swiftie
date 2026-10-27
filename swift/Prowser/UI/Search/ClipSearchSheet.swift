import AppKit
import SwiftUI

struct ClipSearchOptions: Sendable {
    var prompt: String
    var recursive: Bool
    var useCustomDirectory: Bool
    var customDirectory: String
    var threshold: Double
    var ignoreFilenameFilter: Bool
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
    @State private var ignoreFilenameFilter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Search images by text description:")
            TextField("Enter search text", text: $prompt)
                .textFieldStyle(.roundedBorder)
            HStack {
                Text("Minimum similarity")
                AppMiniSlider(value: $threshold, in: 0 ... 1)
                Text(String(format: "%.2f", threshold))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Toggle("", isOn: $useCustomDirectory)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .frame(width: SearchSheetCheckboxLayout.width)
                    TextField("Directory for search", text: $customDirectory)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!useCustomDirectory)
                    Text(validationMark)
                        .frame(width: 20)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(validationColor)
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
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Toggle("", isOn: $ignoreFilenameFilter)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .frame(width: SearchSheetCheckboxLayout.width)
                    Text("All Files (Ignore filter)")
                        .contentShape(Rectangle())
                        .onTapGesture { ignoreFilenameFilter.toggle() }
                        .help("Search all images in scope, not only names matching the current filename filter.")
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { closeDialog() }
                    .keyboardShortcut(.cancelAction)
                Button("Search") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
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

    private var resolvedCustomDirectory: String {
        AppState.expandedSearchDirectoryPath(customDirectory)
    }

    private var customDirectoryIsValid: Bool {
        var isDir: ObjCBool = false
        let path = resolvedCustomDirectory
        guard !path.isEmpty else { return true }
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private var validationMark: String {
        let raw = customDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return "" }
        if customDirectoryIsValid {
            return useCustomDirectory ? "✓" : "-"
        }
        return useCustomDirectory ? "✗" : "-"
    }

    private var validationColor: Color {
        let raw = customDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return .secondary }
        if customDirectoryIsValid { return .green }
        return useCustomDirectory ? .red : .secondary
    }

    private var canSubmit: Bool {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return false }
        if useCustomDirectory {
            let raw = customDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty, !customDirectoryIsValid { return false }
        }
        return true
    }

    private func loadDefaults() {
        ignoreFilenameFilter = appState.config.bool(forKey: "clip_search_ignore_filter", default: false)
        prompt = appState.config.string(forKey: "clip_prompt", default: "")
        recursive = appState.config.bool(forKey: "clip_recursive", default: false)
        if let prime = appState.consumeClipSearchDirectoryPrime() {
            useCustomDirectory = prime.useCustomDirectory
            customDirectory = prime.customDirectory
            if useCustomDirectory {
                recursive = appState.config.bool(forKey: "clip_recursive", default: false)
            }
        } else {
            useCustomDirectory = appState.config.bool(forKey: "clip_search_dir_enabled", default: false)
            customDirectory = appState.config.string(forKey: "clip_search_dir", default: "")
        }
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
        let expandedDir = AppState.expandedSearchDirectoryPath(customDirectory)
        appState.config.updateSetting("clip_search_dir_enabled", value: useCustomDirectory)
        appState.config.updateSetting("clip_search_dir", value: expandedDir)
        appState.config.updateSetting("clip_similarity_threshold", value: threshold)
        appState.config.updateSetting("clip_search_ignore_filter", value: ignoreFilenameFilter)
        closeDialog()
        onSubmit(ClipSearchOptions(
            prompt: trimmed,
            recursive: effectiveRecursive,
            useCustomDirectory: useCustomDirectory,
            customDirectory: expandedDir,
            threshold: threshold,
            ignoreFilenameFilter: ignoreFilenameFilter
        ))
    }
}

/// Shared leading column width for directory + recursive checkboxes in search sheets.
enum SearchSheetCheckboxLayout {
    static let width: CGFloat = 20
}
