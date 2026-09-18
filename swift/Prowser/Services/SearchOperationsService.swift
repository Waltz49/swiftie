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
