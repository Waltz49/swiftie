import AppKit
import Foundation

/// Unified exact-duplicate search entry points (port of `file_operations_manager` find_exact_duplicates*).
@MainActor
enum DuplicateFinderService {
    static func findInDisplayed(appState: AppState) async {
        exitSlideshowIfNeeded(appState: appState)
        let paths = filteredDisplayedPaths(appState: appState)
        guard !paths.isEmpty else {
            StyledMessageDialog.showWarning(title: "No images displayed", message: "")
            return
        }
        await findAndPresent(paths: paths, appState: appState, noDuplicatesScope: "current view")
    }

    static func findRecursive(appState: AppState, overrideRootDirectory: String? = nil) async {
        exitSlideshowIfNeeded(appState: appState)

        guard let root = overrideRootDirectory ?? resolveRecursiveScanRoot(appState: appState) else {
            StyledMessageDialog.showWarning(title: "No directory open", message: "Open a folder first.")
            return
        }

        if FileTreePathRestrictions.isRootOrSystemVolume(root) {
            if root == "/" {
                StyledMessageDialog.showWarning(
                    title: "Action Not Available",
                    message: "This action is not available on the root directory."
                )
            } else {
                StyledMessageDialog.showWarning(
                    title: "Action Not Available",
                    message: "This action is not available on system volumes."
                )
            }
            return
        }

        if appState.fileData.currentViewMode == .browse {
            appState.fileData.setViewMode(.thumbnail)
        }

        let excluded = PathExclusions.excludedPaths(config: appState.config)
        let showHidden = appState.config.bool(forKey: "show_hidden_directories", default: false)
        let paths = DirectoryScanner.scanDirectoryRecursive(
            at: root,
            extensions: appState.config.imageExtensions,
            filterPattern: appState.filterSettings.filterPattern,
            excludedPaths: excluded,
            includeHidden: showHidden
        )

        guard !paths.isEmpty else {
            StyledMessageDialog.showWarning(
                title: "No Images Found",
                message: "No image files found in directory and subdirectories."
            )
            return
        }

        let savedPath = appState.fileData.currentImagePath
        await findAndPresent(
            paths: paths,
            appState: appState,
            noDuplicatesScope: "recursive",
            currentImagePath: savedPath,
            pinDirectoryAfter: root
        )
    }

    private static func findAndPresent(
        paths: [String],
        appState: AppState,
        noDuplicatesScope: String,
        currentImagePath: String? = nil,
        pinDirectoryAfter: String? = nil
    ) async {
        let savedPath = currentImagePath ?? appState.fileData.currentImagePath

        let (groups, cancelled) = await DuplicateHashUIRunner.run(paths: paths)
        if cancelled {
            appState.status.show("Find duplicates cancelled")
            return
        }
        guard let groups else { return }

        let pairs = DuplicateHashService.duplicateGroupPairs(from: groups)
        guard !pairs.isEmpty else {
            StyledMessageDialog.showWarning(
                title: "No Duplicates Found",
                message: "No exact byte-for-byte duplicates found (\(noDuplicatesScope))."
            )
            return
        }

        if let directory = pinDirectoryAfter {
            appState.fileData.setCurrentDirectory(directory)
            appState.config.updateSetting("last_directory", value: directory)
        }

        let count = pairs.count
        DuplicateGroupPresentation.present(
            appState: appState,
            groupPathPairs: pairs,
            currentImagePath: savedPath,
            statusMessage: "Browse mode: Duplicates (\(count) files)"
        )
    }

    static func resolveRecursiveScanRoot(appState: AppState) -> String? {
        if appState.fileTreeKeyboardFocused,
           let outline = appState.fileTreeOutlineView,
           outline.selectedRow >= 0,
           let node = outline.item(atRow: outline.selectedRow) as? FileTreeNode,
           node.isDirectory {
            return node.path
        }
        if let directory = appState.fileData.currentDirectory {
            return directory
        }
        if let first = appState.fileData.displayedImages.first {
            return (first as NSString).deletingLastPathComponent
        }
        return nil
    }

    private static func filteredDisplayedPaths(appState: AppState) -> [String] {
        let displayed = appState.fileData.displayedImages
        let pattern = appState.filterSettings.filterPattern
        if pattern == "*" || pattern.isEmpty { return displayed }
        return displayed.filter {
            DirectoryScanner.matchesGlob(($0 as NSString).lastPathComponent, pattern: pattern)
        }
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
