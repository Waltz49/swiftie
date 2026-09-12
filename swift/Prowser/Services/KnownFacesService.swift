import Foundation

@MainActor
enum KnownFacesService {
    static func reloadSubjects(appState: AppState) -> [KnownFaceSubjectDetail] {
        KnownFacesStore.loadSubjectDetails(dataDirectory: appState.config.dataDirectory)
    }

    static func saveSubjects(appState: AppState, subjects: [KnownFaceSubjectDetail]) {
        do {
            try KnownFacesStore.saveSubjectDetails(
                dataDirectory: appState.config.dataDirectory,
                subjects: subjects
            )
            appState.knownFacesChangedToken += 1
        } catch {
            appState.status.show("Could not save known faces: \(error.localizedDescription)")
        }
    }

    static func applyAssignments(
        appState: AppState,
        imagePath: String,
        assignments: [(name: String, embedding: [Double])],
        subjects: inout [KnownFaceSubjectDetail]
    ) {
        for (name, embedding) in assignments {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalized = trimmed.lowercased()
            var subject = subjects.first {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
            }
            if subject == nil {
                subject = KnownFaceSubjectDetail(id: UUID().uuidString, name: trimmed, samples: [])
                subjects.append(subject!)
            }
            guard let index = subjects.firstIndex(where: { $0.id == subject!.id }) else { continue }
            if subjects[index].samples.count >= KnownFacesStore.maxSamplesPerSubject { continue }
            let existingPaths = Set(subjects[index].samples.map(\.path))
            if existingPaths.contains(imagePath) { continue }
            subjects[index].samples.append(KnownFaceSample(path: imagePath, embedding: embedding))
            if subjects[index].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                subjects[index] = KnownFaceSubjectDetail(
                    id: subjects[index].id,
                    name: trimmed,
                    samples: subjects[index].samples
                )
            }
        }
        subjects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let samples = subjects.flatMap(\.samples)
        saveSubjects(appState: appState, subjects: subjects)
        Task {
            await appState.workers.knownFaces.ensureThumbnails(samples: samples)
        }
    }

    static func openExtractFaces(appState: AppState, imagePath: String?) {
        let path = imagePath ?? appState.fileData.currentImagePath
        guard let path, FileManager.default.fileExists(atPath: path) else {
            appState.status.show("No current image to examine. Select an image first.")
            return
        }
        appState.fileData.setCurrentImagePath(path)
        appState.openSettingsWindow(tab: .faces, userInfo: ["autoExtractFaces": true, "imagePath": path])
    }

    static func examineImage(appState: AppState, imagePath: String, subjects: [KnownFaceSubjectDetail]) async {
        guard appState.workers.knownFaces.isAvailable else {
            appState.status.show("Python face worker is not available.")
            return
        }
        let available = await appState.workers.knownFaces.checkEngineAvailable()
        guard available else {
            appState.status.show("Install face_recognition in the Python environment, then restart.")
            return
        }
        appState.status.show("Detecting faces…")
        do {
            let result = try await appState.workers.knownFaces.detectFaces(
                imagePath: imagePath,
                subjects: subjects
            )
            appState.faceAssignState = FaceAssignState(
                imagePath: result.imagePath,
                previewJPEG: result.previewJPEG,
                faces: result.faces.map {
                    FaceAssignRow(trbl: $0.trbl, embedding: $0.embedding, name: $0.suggestedName)
                }
            )
        } catch {
            appState.status.show(error.localizedDescription)
        }
    }

    static func extractFacesFromSelection(appState: AppState) {
        let paths = SelectionService.orderedSelectedFiles(appState: appState)
        let path = paths.count == 1 ? paths[0] : appState.fileData.currentImagePath
        openExtractFaces(appState: appState, imagePath: path)
    }

    static func cacheSubdirectoryFaces(appState: AppState) {
        guard let directory = appState.fileData.currentDirectory else {
            appState.status.show("No directory open")
            return
        }
        guard appState.workers.face.isAvailable else {
            appState.status.show("Face recognition is not available")
            return
        }
        let depth = appState.config.int(forKey: "search_depth", default: 4)
        appState.workers.face.onFinished = { count in
            Task { @MainActor in
                appState.status.show("Cached faces for \(count) images")
            }
        }
        appState.workers.face.onError = { message in
            Task { @MainActor in appState.status.show(message) }
        }
        do {
            appState.status.show("Caching subdirectory faces…")
            try appState.workers.face.scanDirectory(directory, maxDepth: depth)
        } catch {
            appState.status.show("Face cache failed: \(error.localizedDescription)")
        }
    }
}

extension AppState {
    func completeFaceAssign(imagePath: String, assignments: [(String, [Double])]) {
        var subjects = KnownFacesStore.loadSubjectDetails(dataDirectory: config.dataDirectory)
        KnownFacesService.applyAssignments(
            appState: self,
            imagePath: imagePath,
            assignments: assignments,
            subjects: &subjects
        )
        faceAssignState = nil
    }

    func extractFacesFromSelection() {
        KnownFacesService.extractFacesFromSelection(appState: self)
    }

    func cacheSubdirectoryFaces() {
        KnownFacesService.cacheSubdirectoryFaces(appState: self)
    }
}
