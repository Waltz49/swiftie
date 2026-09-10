import AppKit
import Foundation

/// File tree directory context menu actions. Port of `file_tree_handler.py` tree menu handlers.
@MainActor
final class FileTreeOperationsService {
    private weak var appState: AppState?

    func bind(_ appState: AppState) {
        self.appState = appState
    }

    func showAllImages(in directory: String) {
        guard let appState else { return }
        if FileTreePathRestrictions.isRootOrSystemVolume(directory) {
            showRestrictedAlert(directory: directory)
            return
        }

        let excluded = PathExclusions.excludedPaths(config: appState.config)
        let showHidden = appState.config.bool(forKey: "show_hidden_directories", default: false)
        let maxDepth = appState.config.int(forKey: "search_depth", default: 4)
        let filterPattern = appState.filterSettings.filterPattern
        let images = DirectoryScanner.scanDirectoryRecursive(
            at: directory,
            extensions: appState.config.imageExtensions,
            filterPattern: filterPattern,
            maxDepth: maxDepth,
            excludedPaths: excluded,
            includeHidden: showHidden
        )

        guard !images.isEmpty else {
            let message = filterPattern == "*"
                ? "No images found in \(directory) and its subdirectories."
                : "No images matching filter \"\(filterPattern)\" found in \(directory) and its subdirectories."
            showAlert("No Images Found", informative: message)
            return
        }

        if appState.fileData.currentViewMode == .browse {
            appState.fileData.setViewMode(.thumbnail)
        }
        appState.fileData.setDisplayedImages(images)
        appState.fileData.setCurrentIndex(0)
        appState.fileData.setCurrentImagePath(images[0])
        let status = filterPattern == "*"
            ? "Showing \(images.count) images from \(directory)"
            : "Showing \(images.count) images matching \"\(filterPattern)\" from \(directory)"
        appState.status.show(status)
    }

    func findDuplicateImages(in directory: String) {
        guard let appState else { return }
        if FileTreePathRestrictions.isRootOrSystemVolume(directory) {
            showRestrictedAlert(directory: directory)
            return
        }

        if appState.fileData.currentViewMode == .browse {
            appState.fileData.setViewMode(.thumbnail)
        }

        let excluded = PathExclusions.excludedPaths(config: appState.config)
        let showHidden = appState.config.bool(forKey: "show_hidden_directories", default: false)
        let maxDepth = appState.config.int(forKey: "search_depth", default: 4)
        let paths = DirectoryScanner.scanDirectoryRecursive(
            at: directory,
            extensions: appState.config.imageExtensions,
            filterPattern: appState.filterSettings.filterPattern,
            maxDepth: maxDepth,
            excludedPaths: excluded,
            includeHidden: showHidden
        )

        guard !paths.isEmpty else {
            showAlert("No images found", informative: "No matching images in this folder tree.")
            return
        }

        let duplicates = DuplicateHashService.duplicateSortedPaths(paths)
        guard !duplicates.isEmpty else {
            showAlert("No Duplicates Found", informative: "No exact byte-for-byte duplicates found (recursive).")
            return
        }

        appState.loadDirectory(directory, saveHistory: true)
        appState.config.updateSetting("sort_mode", value: SortMode.duplicates.rawValue)
        appState.fileData.setDisplayedImages(duplicates)
        appState.fileData.setCurrentIndex(0)
        appState.fileData.setCurrentImagePath(duplicates[0])
        appState.fileData.setViewMode(.thumbnail)
        appState.status.show("Found \(duplicates.count) duplicate files")
    }

    func findSimilarImages(in directory: String) {
        guard let appState else { return }
        if FileTreePathRestrictions.isRootOrSystemVolume(directory) {
            showRestrictedAlert(directory: directory)
            return
        }
        appState.status.show("Find visually similar images in folder is not available in the Swift build yet.")
    }

    func clearCache(for directory: String) {
        guard let appState else { return }
        if FileTreePathRestrictions.isRootOrSystemVolume(directory) {
            showRestrictedAlert(directory: directory)
            return
        }

        let images = DirectoryScanner.scanDirectory(
            at: directory,
            extensions: appState.config.imageExtensions,
            filterPattern: "*"
        )
        var cleared = 0
        for path in images {
            appState.metadataCache.invalidate(path: path)
            cleared += 1
        }
        appState.status.show("Cleared cache for \(cleared) images in \((directory as NSString).lastPathComponent)")
    }

    private func showRestrictedAlert(directory: String) {
        let alert = NSAlert()
        alert.messageText = "Action Not Available"
        alert.informativeText = FileTreePathRestrictions.restrictedActionMessage(for: directory)
        alert.runModal()
    }

    private func showAlert(_ title: String, informative: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = informative
        alert.runModal()
    }
}
