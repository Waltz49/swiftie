import Foundation

/// Apply CNN/CLIP search results to app state (port of `similarity_reorder.py` finish paths).
@MainActor
enum ImageSearchResultPresentation {
    /// Shown under the progress bar while CLIP/CNN features are computed or loaded from cache.
    static let searchIndexingDetailText =
        "Reading images and caching search metadata on this Mac. Your image files are not copied or stored by this process."
    static func applyCustomOrderedList(
        appState: AppState,
        orderedPaths: [String],
        currentImagePath: String?,
        statusMessage: String,
        saveHistory: Bool,
        multiSelectReferencePaths: [String]? = nil
    ) {
        let normalized = orderedPaths.compactMap { FileDataModel.normalizePath($0) }
        guard !normalized.isEmpty else { return }
        let restoreMultiSelect = (multiSelectReferencePaths?.count ?? 0) > 1

        if saveHistory {
            appState.directoryHistory.saveCurrent(
                fileData: appState.fileData,
                config: appState.config,
                selection: appState.selection
            )
        }

        DuplicateGroupPresentation.clearDuplicatePresentation(appState: appState)
        appState.config.updateSetting("sort_mode", value: SortMode.custom.rawValue)
        appState.config.updateSetting("sort_reversed", value: false)
        appState.setSpecificFilesActive(true)

        appState.fileData.setDisplayedImages(normalized)

        if restoreMultiSelect, let multiSelectReferencePaths {
            SelectionService.restoreMultiSelectAfterSimilaritySearch(
                appState: appState,
                orderedPaths: normalized,
                referencePaths: multiSelectReferencePaths
            )
        } else {
            if let currentImagePath,
               let norm = FileDataModel.normalizePath(currentImagePath),
               normalized.contains(norm) {
                appState.fileData.setCurrentImagePath(norm)
            } else if let first = normalized.first {
                appState.fileData.setCurrentImagePath(first)
            }
            appState.selection.clear()
        }

        if appState.fileData.currentViewMode == .list {
            appState.toggleListView()
        } else if appState.fileData.currentViewMode != .thumbnail {
            appState.fileData.setViewMode(.thumbnail)
        }

        appState.thumbnailGridHost?.reloadLayoutIfNeeded()
        if restoreMultiSelect {
            appState.thumbnailGridHost?.scrollToSelectionAfterLayout()
        } else {
            syncGridHighlightToCurrentImage(appState: appState, paths: normalized)
        }
        appState.status.show(statusMessage)
        appState.menuRefresh.refreshAll()
    }

    private static func syncGridHighlightToCurrentImage(appState: AppState, paths: [String]) {
        guard appState.fileData.currentViewMode == .thumbnail,
              let grid = appState.thumbnailGridHost,
              let path = appState.fileData.currentImagePath,
              let index = paths.firstIndex(of: path) else { return }
        grid.selectIndex(index, scroll: true, notifyDelegate: false)
        grid.scrollToSelectionAfterLayout()
    }
}
