import AppKit
import Foundation

@MainActor
enum QuickPersonSearchService {
    static let maxImages = 4

    static func run(appState: AppState) async {
        guard FaceRecognitionCapabilities.facesUIEnabled(launchOptions: appState.launchOptions) else { return }

        guard FaceEngine.isBridgeLinked() else {
            StyledMessageDialog.showWarning(
                title: "Search for Person in Current Image",
                message: "Native dlib is not linked in this build. Run swift/Scripts/build_dlib_macos.sh and rebuild."
            )
            return
        }

        let paths = SelectionService.selectedFilesOrCurrent(appState: appState)
        guard !paths.isEmpty else {
            StyledMessageDialog.showWarning(title: "Search for Person in Current Image", message: "Select one or more images first.")
            return
        }
        if paths.count > maxImages {
            StyledMessageDialog.showWarning(
                title: "Search for Person in Current Image",
                message: "Too many images selected (\(paths.count)).\nSelect at most \(maxImages) images."
            )
            return
        }

        do {
            try await FaceModelDownloadService.ensureModelsInstalled(
                profile: appState.config.profilePaths,
                config: appState.config,
                purpose: "Download is required for Search for Person in Current Image (⌃⌘P)."
            )
        } catch ModelDownloadError.userDeclined {
            return
        } catch {
            StyledMessageDialog.showWarning(title: "Search for Person in Current Image", message: error.localizedDescription)
            return
        }

        var samples: [KnownFacesStore.Sample] = []
        for path in paths {
            let detections = FaceEngine.encodeFacesFromPath(path, profile: appState.config.profilePaths)
            guard !detections.isEmpty else { continue }
            let chosen: FaceEngine.FaceDetection
            if detections.count == 1 {
                chosen = detections[0]
            } else if let picked = await FacePickDialog.present(imagePath: path, detections: detections) {
                chosen = picked
            } else {
                return
            }
            samples.append(KnownFacesStore.Sample(path: path, embedding: chosen.encoding))
        }

        guard !samples.isEmpty else {
            StyledMessageDialog.showWarning(title: "Search for Person in Current Image", message: "No faces were detected in the selected images.")
            return
        }

        guard let subjectID = appState.knownFaces.subjectIDForQuickPerson(createIfMissing: true) else {
            StyledMessageDialog.showWarning(
                title: "Search for Person in Current Image",
                message: "Could not create or find the \"\(KnownFacesStore.quickPersonSubjectName)\" person."
            )
            return
        }
        guard appState.knownFaces.replaceAllSamples(subjectID: subjectID, samples: samples) else {
            StyledMessageDialog.showWarning(
                title: "Search for Person in Current Image",
                message: "Could not save the face samples."
            )
            return
        }

        let profile = appState.config.profilePaths
        for sample in samples {
            guard let path = sample.path else { continue }
            _ = FaceSampleThumbnailService.thumbnail(
                profile: profile,
                imagePath: path,
                embedding: sample.embedding
            )
        }

        appState.config.updateSetting("find_person_subject_id", value: subjectID)
        appState.searchOperations.presentPersonSearchDialog(
            sheetWindowTitle: AppState.PersonSearchSheetWindowTitle.personInCurrentImage
        )
    }

}
