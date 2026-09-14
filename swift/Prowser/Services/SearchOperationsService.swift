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
        let paths = filteredDisplayedPaths(appState: appState)
        guard !paths.isEmpty else {
            showAlert("No images displayed", informative: "")
            return
        }
        presentDuplicateResults(paths, appState: appState, scope: "current view")
    }

    func findExactDuplicatesRecursive() {
        guard let appState else { return }
        guard let directory = appState.fileData.currentDirectory else {
            showAlert("No directory open", informative: "Open a folder first.")
            return
        }
        let paths = DirectoryScanner.scanDirectoryRecursive(
            at: directory,
            extensions: appState.config.imageExtensions,
            filterPattern: appState.filterSettings.filterPattern
        )
        guard !paths.isEmpty else {
            showAlert("No images found", informative: "No matching images in this folder tree.")
            return
        }
        presentDuplicateResults(paths, appState: appState, scope: "recursive")
    }

    private func filteredDisplayedPaths(appState: AppState) -> [String] {
        let displayed = appState.fileData.displayedImages
        let pattern = appState.filterSettings.filterPattern
        if pattern == "*" || pattern.isEmpty { return displayed }
        return displayed.filter { DirectoryScanner.matchesGlob(($0 as NSString).lastPathComponent, pattern: pattern) }
    }

    private func presentDuplicateResults(_ paths: [String], appState: AppState, scope: String) {
        exitSlideshowIfNeeded(appState: appState)

        let duplicates = DuplicateHashService.duplicateSortedPaths(paths)
        guard !duplicates.isEmpty else {
            showAlert("No Duplicates Found", informative: "No exact byte-for-byte duplicates found (\(scope)).")
            return
        }

        let savedPath = appState.fileData.currentImagePath
        appState.config.updateSetting("sort_mode", value: SortMode.duplicates.rawValue)
        appState.setSpecificFilesActive(true)
        appState.fileData.setDisplayedImages(duplicates)
        if let savedPath, duplicates.contains(savedPath) {
            appState.fileData.setCurrentImagePath(savedPath)
        } else {
            appState.fileData.setCurrentIndex(0)
            appState.fileData.setCurrentImagePath(duplicates[0])
        }
        appState.fileData.setViewMode(.browse)
    }

    private func exitSlideshowIfNeeded(appState: AppState) {
        switch appState.fileData.currentViewMode {
        case .slideshow, .slideshow2, .slideshow3:
            appState.fileData.setViewMode(.thumbnail)
        default:
            break
        }
    }

    private func showAlert(_ title: String, informative: String) {
        StyledMessageDialog.showWarning(title: title, message: informative)
    }
}
