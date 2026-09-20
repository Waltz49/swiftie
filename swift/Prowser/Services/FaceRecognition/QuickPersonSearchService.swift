import AppKit
import Foundation

@MainActor
enum QuickPersonSearchService {
    static let maxImages = 4

    static func run(appState: AppState) async {
        guard FaceRecognitionCapabilities.facesUIEnabled(launchOptions: appState.launchOptions) else { return }

        let paths = SelectionService.selectedFilesOrCurrent(appState: appState)
        guard !paths.isEmpty else {
            StyledMessageDialog.showWarning(title: "Quick Person Search", message: "Select one or more images first.")
            return
        }
        if paths.count > maxImages {
            StyledMessageDialog.showWarning(
                title: "Quick Person Search",
                message: "Too many images selected (\(paths.count)).\nSelect at most \(maxImages) images."
            )
            return
        }

        do {
            try await FaceModelDownloadService.ensureModelsInstalled(
                profile: appState.config.profilePaths,
                config: appState.config,
                purpose: "Download is required for Quick Person Search (⌃⌘P)."
            )
        } catch ModelDownloadError.userDeclined {
            return
        } catch {
            StyledMessageDialog.showWarning(title: "Quick Person Search", message: error.localizedDescription)
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
            StyledMessageDialog.showWarning(title: "Quick Person Search", message: "No faces were detected in the selected images.")
            return
        }

        guard let subjectID = appState.knownFaces.subjectIDForQuickPerson(createIfMissing: true) else {
            StyledMessageDialog.showWarning(
                title: "Quick Person Search",
                message: "Could not create or find the \"\(KnownFacesStore.quickPersonSubjectName)\" person."
            )
            return
        }
        appState.knownFaces.replaceAllSamples(subjectID: subjectID, samples: samples)

        appState.config.updateSetting("find_person_subject_id", value: subjectID)
        appState.showPersonSearchSheet = true
        appState.syncAuxiliaryDialogs()
    }

}
