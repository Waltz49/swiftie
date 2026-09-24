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

    func presentSimilaritySearchDialog(directoryOverride: String? = nil) {
        guard let appState else { return }
        let treeContext = appState.captureSearchInvocationTreeContext()
        appState.primeSimilaritySearchDirectoryForPresentation(
            directoryOverride: directoryOverride,
            treeContext: treeContext
        )
        appState.showSimilaritySearchSheet = true
        appState.syncAuxiliaryDialogs()
    }

    func presentClipSearchDialog(directoryOverride: String? = nil) {
        guard let appState else { return }
        let treeContext = appState.captureSearchInvocationTreeContext()
        appState.primeClipSearchDirectoryForPresentation(
            directoryOverride: directoryOverride,
            treeContext: treeContext
        )
        if appState.fileData.currentViewMode == .browse {
            appState.closeBrowseView()
        }
        appState.showClipSearchSheet = true
        appState.syncAuxiliaryDialogs()
    }

    func presentPersonSearchDialog(directoryOverride: String? = nil) {
        guard let appState else { return }
        guard FaceRecognitionCapabilities.facesUIEnabled(launchOptions: appState.launchOptions) else { return }
        let treeContext = appState.captureSearchInvocationTreeContext()
        appState.primePersonSearchDirectoryForPresentation(
            directoryOverride: directoryOverride,
            treeContext: treeContext
        )
        if appState.fileData.currentViewMode == .browse {
            appState.closeBrowseView()
        }
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
        // Python Search > Extract Faces → Faces tab examine. In browse, the on-screen image
        // (`currentImagePath`) is authoritative; elsewhere use get_selected_files parity.
        let path: String?
        if appState.fileData.currentViewMode == .browse {
            path = appState.fileData.currentImagePath
        } else {
            let paths = SelectionService.selectedFilesOrCurrent(appState: appState)
            guard paths.count == 1 else { return }
            path = paths[0]
        }
        guard let path, FileManager.default.fileExists(atPath: path) else { return }
        if let index = appState.fileData.displayedImages.firstIndex(of: path) {
            appState.fileData.setCurrentIndex(index)
        }
        appState.fileData.setCurrentImagePath(path)
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
