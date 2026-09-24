import AppKit
import Foundation

/// Pixel MSE “find similar image files” (port of `file_operations_manager.py` similar-image mode).
@MainActor
enum SimilarImageFilesService {
    private enum NoGroupsMessage {
        case displayed
        case folder
        case recursive
    }

    static func findInDisplayed(appState: AppState) async {
        appState.prepareMainViewForImageSearch()
        let paths = filteredDisplayedPaths(appState: appState)
        guard !paths.isEmpty else {
            StyledMessageDialog.showWarning(title: "No images displayed", message: "")
            return
        }
        let saved = currentHighlightPath(appState: appState)
        await analyzeAndPresent(
            paths: paths,
            appState: appState,
            currentImagePath: saved,
            noGroups: .displayed
        )
    }

    static func findRecursive(appState: AppState) async {
        exitSlideshowIfNeeded(appState: appState)
        guard let root = DuplicateFinderService.resolveRecursiveScanRoot(appState: appState) else {
            StyledMessageDialog.showWarning(title: "No directory open", message: "Open a folder first.")
            return
        }
        await findUnderDirectory(
            appState: appState,
            directoryPath: root,
            pinLastDirectory: false,
            emptyScanTitle: "No Images Found",
            emptyScanMessage: "No image files found in directory and subdirectories.",
            notEnoughImages: false,
            noGroups: .recursive
        )
    }

    /// Tree context menu: recursive scan from `directoryPath` (port of `find_similar_image_files_in_directory`).
    static func findInDirectory(appState: AppState, directoryPath: String) async {
        exitSlideshowIfNeeded(appState: appState)
        await findUnderDirectory(
            appState: appState,
            directoryPath: directoryPath,
            pinLastDirectory: false,
            emptyScanTitle: nil,
            emptyScanMessage: nil,
            notEnoughImages: true,
            noGroups: .folder
        )
    }

    private static func findUnderDirectory(
        appState: AppState,
        directoryPath: String,
        pinLastDirectory: Bool,
        emptyScanTitle: String?,
        emptyScanMessage: String?,
        notEnoughImages: Bool,
        noGroups: NoGroupsMessage
    ) async {
        var isDir: ObjCBool = false
        guard !directoryPath.isEmpty,
              FileManager.default.fileExists(atPath: directoryPath, isDirectory: &isDir),
              isDir.boolValue else {
            appState.status.show("Invalid folder")
            return
        }

        if FileTreePathRestrictions.isRootOrSystemVolume(directoryPath) {
            StyledMessageDialog.showWarning(
                title: "Action Not Available",
                message: FileTreePathRestrictions.restrictedActionMessage(for: directoryPath)
            )
            return
        }

        interruptThumbnailLoading(appState: appState)

        appState.prepareMainViewForImageSearch()
        appState.fileData.setCurrentDirectory(directoryPath)

        let excluded = PathExclusions.excludedPaths(config: appState.config)
        let showHidden = appState.config.bool(forKey: "show_hidden_directories", default: false)
        let saved = currentHighlightPath(appState: appState)

        let paths = await scanWithProgress(
            root: directoryPath,
            appState: appState,
            excluded: excluded,
            showHidden: showHidden
        )

        if paths == nil {
            appState.status.show("Find similar images cancelled")
            return
        }
        guard let imagePaths = paths else { return }

        if notEnoughImages {
            if imagePaths.count < 2 {
                StyledMessageDialog.showInformation(
                    title: "Not Enough Images",
                    message: "Need at least two image files under this folder (including subfolders) to search for similar images."
                )
                return
            }
        } else if imagePaths.isEmpty {
            if let emptyScanTitle, let emptyScanMessage {
                StyledMessageDialog.showInformation(title: emptyScanTitle, message: emptyScanMessage)
            }
            return
        }

        if pinLastDirectory {
            appState.config.updateSetting("last_directory", value: directoryPath)
        }

        await analyzeAndPresent(
            paths: imagePaths,
            appState: appState,
            currentImagePath: saved,
            noGroups: noGroups
        )
    }

    private static func scanWithProgress(
        root: String,
        appState: AppState,
        excluded: [String],
        showHidden: Bool
    ) async -> [String]? {
        let panel = CancellableProgressPanelController(
            title: "Find Similar Image Files",
            labelText: "Scanning…",
            maximum: 1,
            indeterminate: true
        )
        panel.show()

        final class CancelBox: @unchecked Sendable {
            var value = false
        }
        let cancelBox = CancelBox()

        let extensions = appState.config.imageExtensions
        let result = await Task.detached {
            RecursiveImageScanRunner.scanImages(
                at: root,
                extensions: extensions,
                excludedPaths: excluded,
                includeHidden: showHidden,
                filterPattern: "*",
                shouldCancel: { cancelBox.value },
                onDirectoryVisited: { relPath, count in
                    Task { @MainActor in
                        cancelBox.value = panel.cancelRequested
                        panel.update(
                            label: "Scanning \(relPath)...\nTotal images found: \(count)"
                        )
                    }
                }
            )
        }.value

        panel.close()

        if panel.cancelRequested || result.cancelled {
            return nil
        }
        return result.paths
    }

    private static func analyzeAndPresent(
        paths: [String],
        appState: AppState,
        currentImagePath: String?,
        noGroups: NoGroupsMessage
    ) async {
        let (pairs, cancelled) = await SimilarImageUIRunner.run(paths: paths)
        if cancelled {
            appState.status.show("Find similar images cancelled")
            return
        }
        guard !pairs.isEmpty else {
            StyledMessageDialog.showInformation(
                title: "No Similar Images Found",
                message: noGroupsMessage(noGroups)
            )
            return
        }

        let hashPairs = pairs.map { (hash: $0.groupKey, path: $0.path) }
        DuplicateGroupPresentation.present(
            appState: appState,
            groupPathPairs: hashPairs,
            currentImagePath: currentImagePath,
            statusMessage: "Browse mode: Similar images (\(hashPairs.count) files)"
        )
    }

    private static func noGroupsMessage(_ scope: NoGroupsMessage) -> String {
        switch scope {
        case .displayed:
            return "No groups of visually similar images were found (compared at 128px width, same aspect ratio)."
        case .folder:
            return "No groups of visually similar images were found under this folder (compared at 128px width, same aspect ratio)."
        case .recursive:
            return "No groups of visually similar images were found in directory and subdirectories (compared at 128px width, same aspect ratio)."
        }
    }

    private static func filteredDisplayedPaths(appState: AppState) -> [String] {
        let displayed = appState.fileData.displayedImages
        let pattern = appState.filterSettings.filterPattern
        if pattern == "*" || pattern.isEmpty { return displayed }
        return displayed.filter {
            DirectoryScanner.matchesGlob(($0 as NSString).lastPathComponent, pattern: pattern)
        }
    }

    private static func currentHighlightPath(appState: AppState) -> String? {
        let path = appState.fileData.currentImagePath
        guard let path, !path.isEmpty else { return nil }
        return path
    }

    private static func interruptThumbnailLoading(appState: AppState) {
        appState.thumbnailGridHost?.thumbnailLoadingActive = false
    }

    private static func exitSlideshowIfNeeded(appState: AppState) {
        switch appState.fileData.currentViewMode {
        case .slideshow, .slideshow2, .slideshow3:
            appState.fileData.setViewMode(.thumbnail)
        default:
            break
        }
    }
}
