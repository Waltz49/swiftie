import AppKit
import SwiftUI

@MainActor
struct FaceRecognitionSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var subjects: [KnownFacesStore.Subject] = []
    @State private var jumpSubjectID: String?
    @State private var status = ""

    private var sortedSubjects: [KnownFacesStore.Subject] {
        subjects.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !FaceEngine.isBridgeLinked() {
                facesUnavailableNote(
                    "Face recognition native library is not linked in this build. "
                        + "Run swift/Scripts/build_dlib_macos.sh and rebuild."
                )
            } else if !FaceModelManifest.isInstalled(profile: appState.config.profilePaths) {
                facesUnavailableNote(
                    "Face models are not installed. Use Search by Person (⌘P), Extract Faces (⇧⌘P), or Quick Person (⌃⌘P) to download them."
                )
                Button("Download Face Models…") { downloadModels() }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            HStack {
                Button("Examine an image…") { examineCurrentImage() }
                    .help("Detect faces in the current browse image and assign them to people in this list.")
                Spacer()
                Picker("Jump to…", selection: $jumpSubjectID) {
                    Text("Jump to…").tag(Optional<String>.none)
                    ForEach(sortedSubjects) { subject in
                        Text(subject.name.isEmpty ? "(unnamed)" : subject.name)
                            .tag(Optional(subject.id))
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if sortedSubjects.isEmpty {
                            Text("No known people yet. Use Examine an image… to assign faces from the current photo.")
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                        }
                        ForEach(sortedSubjects) { subject in
                            FaceSubjectCard(
                                subject: subject,
                                profile: appState.config.profilePaths,
                                onNameChange: { newName in
                                    if appState.knownFaces.updateSubjectName(id: subject.id, name: newName) {
                                        reload()
                                    }
                                },
                                onDeletePerson: {
                                    appState.knownFaces.deleteSubject(id: subject.id)
                                    reload()
                                },
                                onRemoveSample: { index in
                                    appState.knownFaces.removeSample(subjectID: subject.id, at: index)
                                    reload()
                                }
                            )
                            .id(subject.id)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
                .frame(minHeight: 320)
                .onChange(of: jumpSubjectID) { _, newID in
                    guard let newID else { return }
                    withAnimation {
                        proxy.scrollTo(newID, anchor: .top)
                    }
                    jumpSubjectID = nil
                }
            }

            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            reload()
            scheduleAutoExamineIfRequested()
        }
        .onChange(of: appState.settingsOpenRequestToken) { _, _ in
            scheduleAutoExamineIfRequested()
        }
        .onReceive(NotificationCenter.default.publisher(for: .faceModelsInstalled)) { _ in reload() }
    }

    @ViewBuilder
    private func facesUnavailableNote(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.top, 16)
    }

    private func reload() {
        subjects = appState.knownFaces.loadSubjects()
    }

    private func scheduleAutoExamineIfRequested() {
        guard appState.pendingAutoExamineFaces else { return }
        guard appState.requestedSettingsTab == .faceRecognition else { return }
        appState.pendingAutoExamineFaces = false
        Task { await runExamineCurrentImage() }
    }

    private func downloadModels() {
        Task {
            do {
                try await FaceModelDownloadService.ensureModelsInstalled(
                    profile: appState.config.profilePaths,
                    config: appState.config,
                    purpose: "Download is required for the Face Recognition settings tab."
                )
                status = "Face models installed."
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func examineCurrentImage() {
        Task { await runExamineCurrentImage() }
    }

    private func runExamineCurrentImage() async {
        guard let path = appState.fileData.currentImagePath,
              FileManager.default.fileExists(atPath: path) else {
            StyledMessageDialog.showInformation(
                title: "No image",
                message: "No current image to examine. Select an image in the browser first."
            )
            return
        }
        do {
            try await FaceModelDownloadService.ensureModelsInstalled(
                profile: appState.config.profilePaths,
                config: appState.config,
                purpose: "Download is required to examine faces."
            )
        } catch ModelDownloadError.userDeclined {
            return
        } catch {
            status = error.localizedDescription
            return
        }

        let currentSubjects = appState.knownFaces.loadSubjects()
        let profile = appState.config.profilePaths

        let progress = CancellableProgressPanelController(
            title: "Assign faces",
            labelText: "Detecting faces…",
            maximum: 0,
            indeterminate: true
        )
        progress.show()
        let encoded = await Task.detached(priority: .userInitiated) {
            FaceEngine.encodeFacesFromPathWithDisplayImage(path, profile: profile)
        }.value
        progress.close()

        guard let encoded, !encoded.detections.isEmpty else {
            StyledMessageDialog.showWarning(
                title: "No face detected",
                message: "No faces were detected in the selected image."
            )
            return
        }

        guard let results = await FaceAssignDialog.present(
            imagePath: path,
            detections: encoded.detections,
            displayCGImage: encoded.displayCGImage,
            subjects: currentSubjects
        ), !results.isEmpty else {
            return
        }

        appState.knownFaces.mergeAssignedFaces(results)
        reload()
        status = "Saved \(results.count) face assignment(s)."
    }
}

// MARK: - Subject card (port of `_faces_add_card`)

private struct FaceSubjectCard: View {
    let subject: KnownFacesStore.Subject
    let profile: ProfilePaths
    let onNameChange: (String) -> Void
    let onDeletePerson: () -> Void
    let onRemoveSample: (Int) -> Void

    @State private var nameText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Person name (unique)", text: $nameText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 140, maxWidth: 280)
                    .onAppear { nameText = subject.name }
                    .onChange(of: subject.name) { _, newValue in
                        if nameText != newValue { nameText = newValue }
                    }
                    .onChange(of: nameText) { _, newValue in
                        onNameChange(newValue)
                    }
                Spacer(minLength: 8)
                Button(action: onDeletePerson) {
                    Image(systemName: "trash")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .help("Delete person")
            }

            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(Array(subject.samples.enumerated()), id: \.offset) { index, sample in
                        FaceSampleThumbColumn(
                            imagePath: sample.path ?? "",
                            embedding: sample.embedding,
                            profile: profile,
                            onRemove: { onRemoveSample(index) }
                        )
                    }
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(SettingsDialogChrome.border.opacity(0.6), lineWidth: 1)
        )
    }
}

private struct FaceSampleThumbColumn: View {
    let imagePath: String
    let embedding: [Double]
    let profile: ProfilePaths
    let onRemove: () -> Void

    @State private var thumb: NSImage?

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                SettingsDialogChrome.sectionBackground
                if let thumb {
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
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.accentColor, lineWidth: 2)
            )

            HStack {
                Spacer()
                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .frame(width: 24, height: 24)
                .help("Remove sample")
            }
        }
        .task(id: taskKey) {
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
