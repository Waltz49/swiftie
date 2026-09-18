import Foundation

/// Apply CNN/CLIP search results to app state (port of `similarity_reorder.py` finish paths).
@MainActor
enum ImageSearchResultPresentation {
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
        }
        appState.status.show(statusMessage)
        appState.menuRefresh.refreshAll()
    }
}
