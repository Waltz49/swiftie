import AppKit
import Foundation

/// Search menu actions (duplicates, etc.). Port of `file_operations_manager.py` search helpers.
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
}
