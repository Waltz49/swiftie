import AppKit
import SwiftUI

struct PersonSearchSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.themeColors) private var colors
    @Environment(\.dismiss) private var dismiss

    @State private var subjects: [KnownFaceSubjectDetail] = []
    @State private var selectedSubjectID = ""
    @State private var scopeLabel = "Search in displayed files"
    @State private var useCustomDirectory = false
    @State private var directoryPath = ""
    @State private var recursive = false
    @State private var recursiveEnabled = true
    @State private var directoryValidation = PersonDirectoryValidation.empty
    @State private var thumbImages: [NSImage?] = []
    @State private var isSearching = false
    @State private var progressText = ""
    @State private var progressValue: Double = 0
    @State private var searchDepth = 4

    private let thumbSize: CGFloat = 96
    private let thumbGap: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(scopeLabel)
                .font(.body)
                .foregroundStyle(colors.dialogText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 48, alignment: .topLeading)

            personSelectionRow

            directorySelectionRow

            Toggle(recursiveLabel, isOn: $recursive)
                .disabled(!recursiveEnabled)
                .onChange(of: recursive) { _, _ in refreshScopeLabel() }

            if isSearching {
                ProgressView(value: progressValue, total: 1.0)
                Text(progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DialogButtonRow(
                [
                    DialogButton("Cancel", isCancel: true) {
                        if isSearching {
                            appState.workers.personSearch.cancel()
                        } else {
                            dismiss()
                        }
                    },
                    DialogButton(isSearching ? "Stop" : "OK", id: "ok", isDefault: true, isEnabled: okEnabled) {
                        if isSearching {
                            appState.workers.personSearch.cancel()
                        } else {
                            startSearch()
                        }
                    },
                ],
                focusDefaultOnAppear: true
            )
        }
        .padding(20)
        .frame(minWidth: dialogMinWidth, minHeight: 300)
        .themeDialogStyle()
        .persistedDialogGeometry(
            DialogGeometryKey.personSearch,
            defaultWidth: max(520, dialogMinWidth),
            defaultHeight: 340,
            minWidth: dialogMinWidth,
            minHeight: 300,
            windowTitle: "Search by person"
        )
        .onAppear {
            loadSavedSettings()
            refreshScopeLabel()
            refreshRecursiveState()
            refreshThumbnails()
        }
        .onChange(of: appState.knownFacesChangedToken) { _, _ in
            loadSavedSettings()
            refreshThumbnails()
        }
        .onChange(of: selectedSubjectID) { _, _ in refreshThumbnails() }
        .onChange(of: useCustomDirectory) { _, _ in
            refreshScopeLabel()
            refreshRecursiveState()
            validateDirectory()
        }
        .onChange(of: directoryPath) { _, _ in
            refreshScopeLabel()
            refreshRecursiveState()
            validateDirectory()
        }
    }

    private var personSelectionRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Choose a person:")
                if subjects.isEmpty {
                    Text("No known people with face samples. Add people in Settings → Face Recognition, or use Extract Faces first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker("Choose a person", selection: $selectedSubjectID) {
                        ForEach(subjects) { subject in
                            Text(subject.name).tag(subject.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: thumbGap) {
                ForEach(0..<visibleThumbCount, id: \.self) { index in
                    faceThumbView(thumbImages[safe: index] ?? nil)
                }
            }
            .frame(width: thumbStripWidth, alignment: .trailing)
        }
    }

    private var directorySelectionRow: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $useCustomDirectory)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: 20)
                .help("Use custom directory for search")

            TextField("Enter directory path for search", text: $directoryPath)
                .textFieldStyle(.roundedBorder)
                .disabled(!useCustomDirectory)

            Text(directoryValidation.symbol)
                .font(.body.monospaced())
                .foregroundStyle(directoryValidation.color)
                .frame(width: 20)
                .help(directoryValidation.tooltip)

            Button("…") {
                Task { @MainActor in browseDirectory() }
            }
                .frame(width: 30)
                .disabled(!useCustomDirectory)
                .help("Browse for directory")
        }
    }

    @ViewBuilder
    private func faceThumbView(_ image: NSImage?) -> some View {
        ZStack {
            Rectangle()
                .fill(colors.buttonBgDefault)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text("?")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: thumbSize, height: thumbSize)
        .clipped()
    }

    private var recursiveLabel: String {
        "Recursive (search up to \(searchDepth) directories deep)"
    }

    private var visibleThumbCount: Int {
        guard let subject = subjects.first(where: { $0.id == selectedSubjectID }) else { return 1 }
        return max(1, min(4, subject.samples.count))
    }

    private var thumbStripWidth: CGFloat {
        let count = CGFloat(visibleThumbCount)
        return count * thumbSize + max(0, count - 1) * thumbGap
    }

    private var dialogMinWidth: CGFloat {
        max(420, 248 + thumbStripWidth + 28)
    }

    private var okEnabled: Bool {
        guard !isSearching else { return true }
        guard !subjects.isEmpty, !selectedSubjectID.isEmpty else { return false }
        if useCustomDirectory {
            return directoryValidation.isValid
        }
        return true
    }

    @MainActor
    private func loadSavedSettings() {
        searchDepth = appState.config.int(forKey: "search_depth", default: 4)
        subjects = KnownFacesStore.loadSubjectDetails(dataDirectory: appState.config.dataDirectory)
        let settings = appState.config.rawSettings()
        let savedID = (settings["find_person_subject_id"] as? String)
            ?? (settings["person_search_subject_id"] as? String)
            ?? ""
        if !savedID.isEmpty, subjects.contains(where: { $0.id == savedID }) {
            selectedSubjectID = savedID
        } else {
            selectedSubjectID = subjects.first?.id ?? ""
        }

        if let prefill = appState.personSearchPrefillDirectory {
            useCustomDirectory = true
            directoryPath = prefill
            appState.personSearchPrefillDirectory = nil
        } else {
            useCustomDirectory = (settings["find_person_dir_enabled"] as? Bool)
                ?? (settings["person_search_dir_enabled"] as? Bool)
                ?? false
            directoryPath = (settings["find_person_dir"] as? String)
                ?? (settings["person_search_dir"] as? String)
                ?? appState.fileData.currentDirectory
                ?? ""
        }
        recursive = (settings["find_person_recursive"] as? Bool)
            ?? (settings["person_search_recursive"] as? Bool)
            ?? false
        validateDirectory()
    }

    @MainActor
    private func refreshThumbnails() {
        guard let subject = subjects.first(where: { $0.id == selectedSubjectID }) else {
            thumbImages = [nil]
            return
        }
        let cacheDir = appState.config.imageRecognitionCacheDirectory
        if subject.samples.isEmpty {
            thumbImages = [nil]
            return
        }
        thumbImages = subject.samples.map { sample in
            FaceSampleThumbnailLoader.thumbnail(
                imagePath: sample.path,
                embedding: sample.embedding,
                cacheDirectory: cacheDir
            )
        }
    }

    @MainActor
    private func refreshScopeLabel() {
        let currentDirectory = appState.fileData.currentDirectory
        if useCustomDirectory {
            let resolved = expandedDirectoryPath(directoryPath)
            if !directoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               FileManager.default.fileExists(atPath: resolved),
               varIsDirectory(resolved) {
                let name = directoryDisplayName(resolved)
                scopeLabel = recursive
                    ? "Search \(name) and its subdirectories"
                    : "Search \(name)"
            } else if let currentDirectory, varIsDirectory(currentDirectory) {
                let name = directoryDisplayName(currentDirectory)
                scopeLabel = recursive
                    ? "Search \(name) and its subdirectories"
                    : "Search \(name)"
            } else {
                scopeLabel = "Find images containing the selected person"
            }
            return
        }

        let searchDir = currentDirectory
        if recursive, let searchDir, varIsDirectory(searchDir) {
            scopeLabel = "Search in displayed files and files in \(directoryDisplayName(searchDir))"
        } else {
            scopeLabel = "Search in displayed files"
        }
    }

    @MainActor
    private func refreshRecursiveState() {
        let targetDirectory: String?
        if useCustomDirectory {
            let resolved = expandedDirectoryPath(directoryPath)
            targetDirectory = varIsDirectory(resolved) ? resolved : nil
        } else {
            targetDirectory = appState.fileData.currentDirectory
        }
        if let targetDirectory, varIsDirectory(targetDirectory) {
            let hasSubs = directoryHasSubdirectories(targetDirectory)
            recursiveEnabled = hasSubs
            if !hasSubs {
                recursive = false
            }
        } else {
            recursiveEnabled = true
        }
    }

    @MainActor
    private func validateDirectory() {
        let trimmed = directoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            directoryValidation = .empty
            return
        }
        let resolved = expandedDirectoryPath(trimmed)
        if varIsDirectory(resolved) {
            directoryValidation = .valid(enabled: useCustomDirectory)
        } else if FileManager.default.fileExists(atPath: resolved) {
            directoryValidation = .invalid(
                enabled: useCustomDirectory,
                tooltip: "Path exists but is not a directory: \(resolved)"
            )
        } else {
            directoryValidation = .invalid(
                enabled: useCustomDirectory,
                tooltip: "Path does not exist: \(resolved)"
            )
        }
    }

    @MainActor
    private func browseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Select Directory for Search"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        let start = directoryPath.isEmpty ? appState.fileData.currentDirectory : directoryPath
        if let start, !start.isEmpty {
            let expanded = expandedDirectoryPath(start)
            if varIsDirectory(expanded) {
                panel.directoryURL = URL(fileURLWithPath: expanded)
            }
        }
        if panel.runModal() == .OK, let url = panel.url {
            directoryPath = url.path
            validateDirectory()
            refreshScopeLabel()
            refreshRecursiveState()
        }
    }

    @MainActor
    private func startSearch() {
        guard !selectedSubjectID.isEmpty else { return }

        appState.config.updateSetting("find_person_subject_id", value: selectedSubjectID)
        appState.config.updateSetting("find_person_recursive", value: recursive)
        appState.config.updateSetting("find_person_dir_enabled", value: useCustomDirectory)
        appState.config.updateSetting("find_person_dir", value: directoryPath)
        // Legacy keys used by earlier Swift builds.
        appState.config.updateSetting("person_search_subject_id", value: selectedSubjectID)
        appState.config.updateSetting("person_search_recursive", value: recursive)
        appState.config.updateSetting("person_search_dir_enabled", value: useCustomDirectory)
        appState.config.updateSetting("person_search_dir", value: directoryPath)

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

    private func expandedDirectoryPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private func varIsDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func directoryDisplayName(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let name = (trimmed as NSString).lastPathComponent
        return name.isEmpty ? "." : name
    }

    private func directoryHasSubdirectories(_ path: String) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        return contents.contains { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }
}

private enum PersonDirectoryValidation {
    case empty
    case valid(enabled: Bool)
    case invalid(enabled: Bool, tooltip: String)

    var symbol: String {
        switch self {
        case .empty:
            return ""
        case .valid(let enabled):
            return enabled ? "✓" : "−"
        case .invalid(let enabled, _):
            return enabled ? "✗" : "−"
        }
    }

    var color: Color {
        switch self {
        case .empty:
            return .secondary
        case .valid(let enabled):
            return enabled ? .green : .secondary
        case .invalid(let enabled, _):
            return enabled ? .red : .secondary
        }
    }

    var tooltip: String {
        switch self {
        case .empty:
            return ""
        case .valid(let enabled):
            return enabled ? "Valid directory" : ""
        case .invalid(_, let tooltip):
            return tooltip
        }
    }

    var isValid: Bool {
        switch self {
        case .empty, .valid:
            return true
        case .invalid:
            return false
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
