import AppKit
import SwiftUI

@MainActor
struct FaceRecognitionSettingsTab: View {
    @Environment(AppState.self) private var appState
    @Environment(\.themeColors) private var colors

    @State private var subjects: [KnownFaceSubjectDetail] = []
    @State private var engineAvailable = false
    @State private var jumpSubjectID = ""
    @State private var thumbReloadToken = 0

    private let thumbSize: CGFloat = 96

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Face Recognition").font(.title2)

                    if !engineAvailable {
                        Text(
                            "Face recognition is not available. Install the optional package:\n\n"
                            + "  pip install face_recognition\n\n"
                            + "Then restart the application. The Faces tab and Cache Faces (⌘=) will then work."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        HStack {
                            Button("Examine an image…") {
                                Task { await examineCurrentImage() }
                            }
                            .help("Detect faces in the current browse image and assign them to people in this list.")

                            Spacer()

                            Picker("Jump to", selection: $jumpSubjectID) {
                                Text("Jump to…").tag("")
                                ForEach(subjects) { subject in
                                    Text(subject.name).tag(subject.id)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 180)
                            .onChange(of: jumpSubjectID) { _, newValue in
                                guard !newValue.isEmpty else { return }
                                withAnimation { proxy.scrollTo(newValue, anchor: .top) }
                                jumpSubjectID = ""
                            }
                        }

                        if subjects.isEmpty {
                            Text("No known people yet. Use Examine an image… or Quick Person Search to add face samples.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach($subjects) { $subject in
                                subjectCard(subject: $subject)
                                    .id(subject.id)
                            }
                        }

                        Button("Add person") {
                            addPerson()
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .onAppear {
            Task { await reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .prowserOpenSettingsTab)) { notification in
            guard let tab = notification.userInfo?["tab"] as? String, tab == SettingsTab.faces.rawValue else { return }
            if notification.userInfo?["autoExtractFaces"] as? Bool == true {
                Task {
                    await reload()
                    if let path = notification.userInfo?["imagePath"] as? String {
                        await KnownFacesService.examineImage(appState: appState, imagePath: path, subjects: subjects)
                    } else {
                        await examineCurrentImage()
                    }
                }
            }
        }
        .onChange(of: appState.knownFacesChangedToken) { _, _ in
            Task { await reload() }
        }
    }

    @ViewBuilder
    private func subjectCard(subject: Binding<KnownFaceSubjectDetail>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Person name (unique)", text: subject.name)
                    .textFieldStyle(.roundedBorder)
                Button {
                    deleteSubject(id: subject.wrappedValue.id)
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete person")
            }

            HStack(spacing: 8) {
                ForEach(Array(subject.wrappedValue.samples.enumerated()), id: \.offset) { index, sample in
                    VStack(spacing: 4) {
                        faceThumb(sample: sample)
                        Button {
                            removeSample(subjectID: subject.wrappedValue.id, index: index)
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                        }
                        .help("Remove sample")
                    }
                }
                Spacer()
            }
        }
        .padding(10)
        .background(colors.buttonBgDefault.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onChange(of: subject.wrappedValue.name) { _, _ in
            persistSubjects()
        }
    }

    @ViewBuilder
    private func faceThumb(sample: KnownFaceSample) -> some View {
        let image = FaceSampleThumbnailLoader.thumbnail(
            imagePath: sample.path,
            embedding: sample.embedding,
            cacheDirectory: appState.config.imageRecognitionCacheDirectory
        )
        ZStack {
            Rectangle().fill(colors.buttonBgDefault)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text("?")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: thumbSize, height: thumbSize)
        .clipped()
        .id("\(thumbReloadToken)-\(sample.path)-\(sample.embedding.first ?? 0)")
    }

    private func reload() async {
        subjects = KnownFacesService.reloadSubjects(appState: appState)
        engineAvailable = await appState.workers.knownFaces.checkEngineAvailable()
        thumbReloadToken += 1
        if engineAvailable {
            await appState.workers.knownFaces.ensureThumbnails(samples: subjects.flatMap(\.samples))
            thumbReloadToken += 1
        }
    }

    private func examineCurrentImage() async {
        guard let path = appState.fileData.currentImagePath else {
            appState.status.show("No current image to examine. Select an image in the browser first.")
            return
        }
        await KnownFacesService.examineImage(appState: appState, imagePath: path, subjects: subjects)
    }

    private func addPerson() {
        let subject = KnownFaceSubjectDetail(id: UUID().uuidString, name: "New Person", samples: [])
        subjects.append(subject)
        subjects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persistSubjects()
    }

    private func deleteSubject(id: String) {
        subjects.removeAll { $0.id == id }
        persistSubjects()
    }

    private func removeSample(subjectID: String, index: Int) {
        guard let subjectIndex = subjects.firstIndex(where: { $0.id == subjectID }) else { return }
        var samples = subjects[subjectIndex].samples
        guard samples.indices.contains(index) else { return }
        samples.remove(at: index)
        if samples.isEmpty {
            subjects.remove(at: subjectIndex)
        } else {
            subjects[subjectIndex] = KnownFaceSubjectDetail(
                id: subjects[subjectIndex].id,
                name: subjects[subjectIndex].name,
                samples: samples
            )
        }
        persistSubjects()
    }

    private func persistSubjects() {
        KnownFacesService.saveSubjects(appState: appState, subjects: subjects)
        thumbReloadToken += 1
    }
}
