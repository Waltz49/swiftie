import AppKit
import Foundation

/// Search menu actions (duplicates, similarity, CLIP, etc.).
@MainActor
final class SearchOperationsService {
    private weak var appState: AppState?

    func bind(_ appState: AppState) {
        self.appState = appState
    }

    func findExactDuplicatesInDisplayed() {
        guard let appState else { return }
        Task { @MainActor in
            await DuplicateFinderService.findInDisplayed(appState: appState)
        }
    }

    func findExactDuplicatesRecursive() {
        guard let appState else { return }
        Task { @MainActor in
            await DuplicateFinderService.findRecursive(appState: appState)
        }
    }

    func findSimilarImageFilesInDisplayed() {
        guard let appState else { return }
        Task { @MainActor in
            await SimilarImageFilesService.findInDisplayed(appState: appState)
        }
    }

    func findSimilarImageFilesRecursive() {
        guard let appState else { return }
        Task { @MainActor in
            await SimilarImageFilesService.findRecursive(appState: appState)
        }
    }

    func presentSimilaritySearchDialog() {
        guard let appState else { return }
        appState.showSimilaritySearchSheet = true
        appState.syncAuxiliaryDialogs()
    }

    func presentClipSearchDialog() {
        guard let appState else { return }
        appState.showClipSearchSheet = true
        appState.syncAuxiliaryDialogs()
    }

    func presentPersonSearchDialog() {
        guard let appState else { return }
        guard FaceRecognitionCapabilities.facesUIEnabled(launchOptions: appState.launchOptions) else { return }
        appState.showPersonSearchSheet = true
        appState.syncAuxiliaryDialogs()
    }

    func runPersonSearch(options: PersonSearchOptions) {
        guard let appState else { return }
        Task { @MainActor in
            await PersonSearchService.run(appState: appState, options: options)
        }
    }

    func runQuickPersonSearch() {
        guard let appState else { return }
        Task { @MainActor in
            await QuickPersonSearchService.run(appState: appState)
        }
    }

    func cacheFaces() {
        guard let appState else { return }
        Task { @MainActor in
            await FaceCacheUIService.cacheFaces(appState: appState)
        }
    }

    func extractFaces() {
        guard let appState else { return }
        guard FaceRecognitionCapabilities.facesUIEnabled(launchOptions: appState.launchOptions) else { return }
        guard FaceEngine.isBridgeLinked() else {
            StyledMessageDialog.showWarning(
                title: "Face recognition unavailable",
                message: "Native dlib is not linked in this build."
            )
            return
        }
        guard let path = appState.fileData.currentImagePath, FileManager.default.fileExists(atPath: path) else {
            StyledMessageDialog.showInformation(
                title: "No image",
                message: "No current image to examine. Select an image in the browser first."
            )
            return
        }
        appState.openSettingsWindow(tab: .faceRecognition, userInfo: ["autoExamineFaces": true])
    }

    func runSimilaritySearch(options: SimilaritySearchOptions) {
        guard let appState else { return }
        Task { @MainActor in
            await SimilaritySearchService.run(appState: appState, options: options)
        }
    }

    func runClipSearch(options: ClipSearchOptions) {
        guard let appState else { return }
        Task { @MainActor in
            await ClipTextSearchService.run(appState: appState, options: options)
        }
    }
}
