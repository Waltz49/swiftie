import AppKit
import SwiftUI

struct PersonSearchSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var subjects: [KnownFaceSubject] = []
    @State private var selectedSubjectID = ""
    @State private var useCustomDirectory = false
    @State private var directoryPath = ""
    @State private var recursive = false
    @State private var isSearching = false
    @State private var progressText = ""
    @State private var progressValue: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Search for images containing a known person:")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            if subjects.isEmpty {
                Text("No known people with face samples. Add people in Settings → Face Recognition, or use Extract Faces first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Person", selection: $selectedSubjectID) {
                    ForEach(subjects) { subject in
                        Text("\(subject.name) (\(subject.sampleCount))").tag(subject.id)
                    }
                }
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
                        appState.workers.personSearch.cancel()
                    } else {
                        dismiss()
                    }
                }
                Button(isSearching ? "Stop" : "Search") {
                    if isSearching {
                        appState.workers.personSearch.cancel()
                    } else {
                        startSearch()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(subjects.isEmpty || selectedSubjectID.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { loadSavedSettings() }
    }

    @MainActor
    private func loadSavedSettings() {
        subjects = KnownFacesStore.loadSubjects(dataDirectory: appState.config.dataDirectory)
        let settings = appState.config.rawSettings()
        if let savedID = settings["person_search_subject_id"] as? String,
           subjects.contains(where: { $0.id == savedID }) {
            selectedSubjectID = savedID
        } else {
            selectedSubjectID = subjects.first?.id ?? ""
        }
        if let prefill = appState.personSearchPrefillDirectory {
            useCustomDirectory = true
            directoryPath = prefill
            appState.personSearchPrefillDirectory = nil
        } else {
            useCustomDirectory = settings["person_search_dir_enabled"] as? Bool ?? false
            directoryPath = settings["person_search_dir"] as? String ?? appState.fileData.currentDirectory ?? ""
        }
        recursive = settings["person_search_recursive"] as? Bool ?? false
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
        guard !selectedSubjectID.isEmpty else { return }

        appState.config.updateSetting("person_search_subject_id", value: selectedSubjectID)
        appState.config.updateSetting("person_search_dir_enabled", value: useCustomDirectory)
        appState.config.updateSetting("person_search_dir", value: directoryPath)
        appState.config.updateSetting("person_search_recursive", value: recursive)

        let options = SimilaritySearchOptions(
            useCustomDirectory: useCustomDirectory,
            directoryPath: directoryPath,
            recursive: recursive
        )

        isSearching = true
        progressText = "Starting person search…"
        progressValue = 0

        Task { @MainActor in
            do {
                let (paths, personName) = try await appState.searchOperations.runPersonSearch(
                    subjectID: selectedSubjectID,
                    options: options
                ) { current, total, stage in
                    if total > 0 {
                        progressValue = Double(current) / Double(total)
                    }
                    progressText = stageLabel(stage, current: current, total: total)
                }
                isSearching = false
                dismiss()
                appState.searchOperations.applyPersonSearchResults(paths, personName: personName)
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
        case "scanning_faces":
            return "Scanning faces \(current)/\(total)…"
        case "matching":
            return "Matching faces \(current)/\(total)…"
        default:
            return total > 0 ? "Processing \(current)/\(total)…" : "Searching…"
        }
    }
}
