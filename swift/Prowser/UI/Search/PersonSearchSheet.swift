import AppKit
import SwiftUI

@MainActor
struct PersonSearchSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.closeDialog) private var closeDialog
    let onSubmit: (PersonSearchOptions) -> Void

    @State private var subjects: [KnownFacesStore.Subject] = []
    @State private var selectedSubjectID = ""
    @State private var recursive = false
    @State private var recursiveEnabled = true
    @State private var useCustomDirectory = false
    @State private var customDirectory = ""
    @State private var dirLabelText = "Search in displayed files"

    private let thumbSize: CGFloat = 96
    private let thumbGap: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(dirLabelText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 44, alignment: .topLeading)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Choose a person:")
                    Picker("", selection: $selectedSubjectID) {
                        ForEach(sortedSubjects, id: \.id) { subject in
                            Text(displayName(subject.name)).tag(subject.id)
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 200)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                personThumbStrip
            }

            HStack(spacing: 10) {
                Toggle("", isOn: $useCustomDirectory)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .frame(width: 20)
                    .help("Use custom directory for search")
                TextField("Enter directory path for search", text: $customDirectory)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!useCustomDirectory)
                Text(validationMark)
                    .frame(width: 20)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(validationColor)
                Button("…") { browseDirectory() }
                    .frame(width: 30)
                    .disabled(!useCustomDirectory)
                    .help("Browse for directory")
            }

            Toggle(isOn: $recursive) {
                Text("Recursive (search up to \(searchDepth) directories deep)")
            }
            .disabled(!recursiveEnabled)
            .help(
                "If checked, searches recursively in subdirectories (up to \(searchDepth) levels)\n"
                    + "and opens results in a new level.\n"
                    + "Depth is controlled by 'Search depth' in the Directories settings tab."
            )

            HStack {
                Spacer()
                Button("Cancel") { closeDialog() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(minWidth: dialogMinWidth)
        .onAppear { reload() }
        .onChange(of: selectedSubjectID) { _, _ in refreshChrome() }
        .onChange(of: recursive) { _, _ in refreshDirLabel() }
        .onChange(of: useCustomDirectory) { _, _ in refreshChrome() }
        .onChange(of: customDirectory) { _, _ in refreshChrome() }
    }

    private var sortedSubjects: [KnownFacesStore.Subject] {
        subjects.sorted {
            displayName($0.name).localizedCaseInsensitiveCompare(displayName($1.name)) == .orderedAscending
        }
    }

    private var selectedSubject: KnownFacesStore.Subject? {
        subjects.first { $0.id == selectedSubjectID }
    }

    private var searchDepth: Int {
        appState.config.int(forKey: "search_depth", default: 4)
    }

    private var dialogMinWidth: CGFloat {
        let n = thumbStripCount
        let thumbStripW = CGFloat(n) * thumbSize + CGFloat(max(0, n - 1)) * thumbGap
        return max(420, 248 + thumbStripW + 28)
    }

    private var thumbStripCount: Int {
        guard let subject = selectedSubject else { return 1 }
        let valid = subject.samples.filter { $0.embedding.count == 128 }.prefix(4)
        return valid.isEmpty ? 1 : valid.count
    }

    @ViewBuilder
    private var personThumbStrip: some View {
        let samples = selectedSubject?.samples.filter { $0.embedding.count == 128 }.prefix(4) ?? []
        let n = samples.isEmpty ? 1 : samples.count
        let width = CGFloat(n) * thumbSize + CGFloat(max(0, n - 1)) * thumbGap
        HStack(spacing: thumbGap) {
            if samples.isEmpty {
                PersonSearchFaceThumb(
                    imagePath: "",
                    embedding: [],
                    profile: appState.config.profilePaths
                )
            } else {
                ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                    PersonSearchFaceThumb(
                        imagePath: sample.path ?? "",
                        embedding: sample.embedding,
                        profile: appState.config.profilePaths
                    )
                }
            }
        }
        .frame(width: width, alignment: .trailing)
    }

    private var resolvedCustomDirectory: String {
        customDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            .expandingTildeInPath
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
        guard !selectedSubjectID.isEmpty else { return false }
        if useCustomDirectory {
            let raw = customDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty, !customDirectoryIsValid { return false }
        }
        return true
    }

    private func displayName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unnamed" : trimmed
    }

    private static func dirDisplayName(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty { return "." }
        return (trimmed as NSString).lastPathComponent
    }

    private static func hasSubdirectories(_ directoryPath: String) -> Bool {
        var isDir: ObjCBool = false
        guard !directoryPath.isEmpty,
              FileManager.default.fileExists(atPath: directoryPath, isDirectory: &isDir),
              isDir.boolValue else { return false }
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directoryPath) else { return false }
        for name in contents {
            var childIsDir: ObjCBool = false
            let child = (directoryPath as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: child, isDirectory: &childIsDir), childIsDir.boolValue {
                return true
            }
        }
        return false
    }

    private func refreshChrome() {
        refreshDirLabel()
        refreshRecursiveEnable()
    }

    private func refreshDirLabel() {
        if useCustomDirectory {
            let path = customDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = resolvedCustomDirectory
            if !path.isEmpty, customDirectoryIsValid {
                let name = Self.dirDisplayName(resolved)
                if recursive {
                    dirLabelText = "Search \(name) and its subdirectories"
                } else {
                    dirLabelText = "Search \(name)"
                }
            } else if let directory = SearchImagePathCollector.currentSearchDirectory(appState: appState) {
                let name = Self.dirDisplayName(directory)
                if recursive {
                    dirLabelText = "Search \(name) and its subdirectories"
                } else {
                    dirLabelText = "Search \(name)"
                }
            } else {
                dirLabelText = "Find images containing the selected person"
            }
            return
        }

        let searchDir = SearchImagePathCollector.currentSearchDirectory(appState: appState)
        if recursive, let searchDir {
            let name = Self.dirDisplayName(searchDir)
            dirLabelText = "Search in displayed files and files in \(name)"
        } else {
            dirLabelText = "Search in displayed files"
        }
    }

    private func refreshRecursiveEnable() {
        var targetDir: String?
        if useCustomDirectory {
            let resolved = resolvedCustomDirectory
            if customDirectoryIsValid, !resolved.isEmpty {
                targetDir = resolved
            }
        } else {
            targetDir = SearchImagePathCollector.currentSearchDirectory(appState: appState)
        }

        if let targetDir, !Self.hasSubdirectories(targetDir) {
            recursiveEnabled = false
            recursive = false
        } else {
            recursiveEnabled = true
        }
    }

    private func reload() {
        subjects = appState.knownFaces.loadSubjects()
        if subjects.isEmpty {
            StyledMessageDialog.showInformation(
                title: "Search by person",
                message: "No known people. Add people and face samples in Settings → Face Recognition, then try again."
            )
            closeDialog()
            return
        }
        recursive = appState.config.bool(forKey: "find_person_recursive", default: false)
        useCustomDirectory = appState.config.bool(forKey: "find_person_dir_enabled", default: false)
        customDirectory = appState.config.string(forKey: "find_person_dir", default: "")
        let saved = appState.config.string(forKey: "find_person_subject_id", default: "")
        if subjects.contains(where: { $0.id == saved }) {
            selectedSubjectID = saved
        } else {
            selectedSubjectID = sortedSubjects.first?.id ?? ""
        }
        if customDirectory.isEmpty, let dir = SearchImagePathCollector.currentSearchDirectory(appState: appState) {
            customDirectory = dir
        }
        refreshChrome()
    }

    private func browseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Directory for Search"
        let current = resolvedCustomDirectory
        if !current.isEmpty, customDirectoryIsValid {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        } else if let dir = SearchImagePathCollector.currentSearchDirectory(appState: appState) {
            panel.directoryURL = URL(fileURLWithPath: dir, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        customDirectory = url.path
        refreshChrome()
    }

    private func submit() {
        appState.config.updateSetting("find_person_subject_id", value: selectedSubjectID)
        appState.config.updateSetting("find_person_recursive", value: recursive)
        appState.config.updateSetting("find_person_dir_enabled", value: useCustomDirectory)
        appState.config.updateSetting("find_person_dir", value: customDirectory.trimmingCharacters(in: .whitespacesAndNewlines))
        onSubmit(
            PersonSearchOptions(
                subjectID: selectedSubjectID,
                recursive: recursive,
                useCustomDirectory: useCustomDirectory,
                customDirectory: customDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        closeDialog()
    }
}

private struct PersonSearchFaceThumb: View {
    let imagePath: String
    let embedding: [Double]
    let profile: ProfilePaths

    @State private var thumb: NSImage?

    var body: some View {
        ZStack {
            SettingsDialogChrome.sectionBackground
            if embedding.count == 128, let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .scaledToFill()
            } else {
                Text("?")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 96, height: 96)
        .clipped()
        .task(id: taskKey) {
            guard embedding.count == 128 else {
                thumb = nil
                return
            }
            let pngData = await Task.detached(priority: .utility) {
                FaceSampleThumbnailService.thumbnailPNGData(
                    profile: profile,
                    imagePath: imagePath,
                    embedding: embedding
                )
            }.value
            thumb = pngData.flatMap { NSImage(data: $0) }
        }
    }

    private var taskKey: String {
        let fk = FaceSampleCache.embeddingToFaceKey(embedding) ?? ""
        return "\(imagePath)|\(fk)"
    }
}

private extension String {
    var expandingTildeInPath: String {
        (self as NSString).expandingTildeInPath
    }
}
