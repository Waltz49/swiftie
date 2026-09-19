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

        appState.directoryHistory.saveCurrent(
            fileData: appState.fileData,
            config: appState.config,
            selection: appState.selection
        )
        appState.clearBrowseReturnState()
        if appState.fileData.currentViewMode == .browse {
            appState.fileData.setViewMode(.thumbnail)
        }
        let baseDirectory = URL(fileURLWithPath: images[0]).deletingLastPathComponent().path
        appState.setSpecificFilesActive(true)
        appState.fileData.setCurrentDirectory(baseDirectory)
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
        Task { @MainActor in
            await DuplicateFinderService.findRecursive(
                appState: appState,
                overrideRootDirectory: directory
            )
        }
    }

    func findSimilarImages(in directory: String) {
        guard let appState else { return }
        Task { @MainActor in
            await SimilarImageFilesService.findInDirectory(appState: appState, directoryPath: directory)
        }
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
        StyledMessageDialog.showWarning(
            title: "Action Not Available",
            message: FileTreePathRestrictions.restrictedActionMessage(for: directory)
        )
    }

    private func showAlert(_ title: String, informative: String) {
        StyledMessageDialog.showWarning(title: title, message: informative)
    }
}
