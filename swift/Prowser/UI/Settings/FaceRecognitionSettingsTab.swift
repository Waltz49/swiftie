import SwiftUI

@MainActor
struct FaceRecognitionSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var subjects: [KnownFaceSubject] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Face Recognition").font(.title2)

                SettingsSection(title: "Availability") {
                    Label(
                        appState.workers.face.isAvailable ? "Face engine available" : "Face engine unavailable",
                        systemImage: appState.workers.face.isAvailable ? "checkmark.circle" : "xmark.circle"
                    )
                    .foregroundStyle(appState.workers.face.isAvailable ? .green : .secondary)
                    if !appState.workers.face.isAvailable {
                        Text("Install face_recognition in the Python environment and restart workers.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                SettingsSection(title: "Data Paths") {
                    SettingsPathRow(
                        title: "Known faces",
                        path: appState.config.dataDirectory.appendingPathComponent("known_faces.json").path
                    )
                    SettingsPathRow(
                        title: "Face cache",
                        path: appState.config.dataDirectory.appendingPathComponent("face_cache").path
                    )
                }

                SettingsSection(title: "Known People") {
                    if subjects.isEmpty {
                        Text("No known people with face samples yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(subjects) { subject in
                            HStack {
                                Text(subject.name)
                                Spacer()
                                Text("\(subject.sampleCount) sample(s)")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { reloadSubjects() }
    }

    private func reloadSubjects() {
        subjects = KnownFacesStore.loadSubjects(dataDirectory: appState.config.dataDirectory)
    }
}
