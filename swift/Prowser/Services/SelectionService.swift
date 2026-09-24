import Foundation

/// Centralized thumbnail selection operations. Port of `selection_manager.py` + `navigation_manager.py`.
@MainActor
enum SelectionService {
    static func orderedSelectedFiles(appState: AppState) -> [String] {
        let selected = appState.selection.selectedFiles
        guard !selected.isEmpty else { return [] }
        return appState.fileData.displayedImages.filter { selected.contains($0) }
    }

    /// After ⌘K with multiple reference images: keep refs selected; active = last ref in similarity order (⇧→ extends).
    static func restoreMultiSelectAfterSimilaritySearch(
        appState: AppState,
        orderedPaths: [String],
        referencePaths: [String]
    ) {
        let refKeys = Set(
            referencePaths.compactMap { FileDataModel.normalizePath($0) }
        )
        let refsInSortOrder = orderedPaths.filter { refKeys.contains($0) }
        guard !refsInSortOrder.isEmpty else {
            appState.selection.clear()
            return
        }

        appState.selection.selectedFiles = Set(refsInSortOrder)
        let firstIndex = orderedPaths.firstIndex(of: refsInSortOrder[0]) ?? 0
        let lastPath = refsInSortOrder[refsInSortOrder.count - 1]
        let lastIndex = orderedPaths.firstIndex(of: lastPath) ?? firstIndex

        appState.fileData.setCurrentIndex(lastIndex)
        appState.fileData.setCurrentImagePath(lastPath)
        appState.selection.rangeAnchorIndex = firstIndex
        appState.selection.lastClickedIndex = lastIndex
        appState.selection.mostRecentSelectedPath = lastPath
        appState.selection.resetCmdMulti()
        appState.selection.emitSelectionChanged(highlightIndex: lastIndex)
    }

    /// Python `SelectionManager.get_selected_files`: ordered selection, falling back to the highlighted image.
    static func selectedFilesOrCurrent(appState: AppState) -> [String] {
        let ordered = orderedSelectedFiles(appState: appState)
        if !ordered.isEmpty { return ordered }
        if let current = appState.fileData.currentImagePath,
           appState.fileData.displayedImages.contains(current) {
            return [current]
        }
        return []
    }

    static func selectedIndices(appState: AppState) -> Set<Int> {
        let images = appState.fileData.displayedImages
        var indices = Set<Int>()
        for (index, path) in images.enumerated() where appState.selection.selectedFiles.contains(path) {
            indices.insert(index)
        }
        return indices
    }

    static func clearSelection(appState: AppState, preserveCurrentImage: Bool = false) {
        let displayed = appState.fileData.displayedImages
        let selected = appState.selection.selectedFiles
        let recent = appState.selection.mostRecentSelectedPath

        if !preserveCurrentImage {
            if let recent, selected.contains(recent), displayed.contains(recent) {
                appState.fileData.setCurrentImagePath(recent)
            } else if !selected.isEmpty {
                var lastPath: String?
                for path in displayed where selected.contains(path) {
                    lastPath = path
                }
                if let lastPath {
                    appState.fileData.setCurrentImagePath(lastPath)
                }
            }
        }

        appState.selection.selectedFiles.removeAll()
        appState.selection.rangeAnchorIndex = nil
        appState.selection.lastClickedIndex = nil
        appState.selection.mostRecentSelectedPath = nil
        appState.selection.resetCmdMulti()
        appState.selection.emitSelectionChanged(highlightIndex: appState.fileData.currentIndex)
    }

    static func selectThumbnail(appState: AppState, index: Int, addToSelection: Bool) {
        let images = appState.fileData.displayedImages
        guard index >= 0, index < images.count else { return }

        let filePath = images[index]
        let previousCurrentPath = appState.fileData.currentImagePath
        appState.fileData.setCurrentIndex(index)
        appState.fileData.setCurrentImagePath(filePath)
        appState.selection.lastClickedIndex = index

        if addToSelection {
            if appState.selection.selectedFiles.isEmpty,
               let previousCurrentPath,
               previousCurrentPath != filePath,
               !appState.selection.selectedFiles.contains(previousCurrentPath) {
                appState.selection.selectedFiles.insert(previousCurrentPath)
            }

            if filePath == appState.fileData.currentImagePath,
               appState.selection.selectedFiles.isEmpty,
               !appState.selection.multiSelectMode {
                appState.selection.selectedFiles.insert(filePath)
            } else if appState.selection.selectedFiles.contains(filePath),
                      appState.selection.selectedFiles.count > 1 {
                appState.selection.selectedFiles.remove(filePath)
            } else {
                appState.selection.selectedFiles.insert(filePath)
            }
            appState.selection.resetCmdMulti()
        } else {
            appState.selection.selectedFiles = [filePath]
            appState.selection.rangeAnchorIndex = nil
            appState.selection.resetCmdMulti()
        }

        appState.selection.mostRecentSelectedPath = filePath
        appState.selection.emitSelectionChanged(highlightIndex: index)
    }

    static func resolveRangeAnchor(appState: AppState, anchor: Int?, currentIndex: Int) -> Int? {
        if let anchor { return anchor }
        if let rangeAnchor = appState.selection.rangeAnchorIndex { return rangeAnchor }
        if let lastClicked = appState.selection.lastClickedIndex { return lastClicked }
        toggleIndex(appState: appState, index: currentIndex)
        appState.selection.lastClickedIndex = currentIndex
        appState.selection.rangeAnchorIndex = currentIndex
        return nil
    }

    static func handleRangeSelection(appState: AppState, currentIndex: Int, anchor: Int? = nil) {
        let images = appState.fileData.displayedImages
        guard !images.isEmpty else { return }

        guard let anchorIndex = resolveRangeAnchor(appState: appState, anchor: anchor, currentIndex: currentIndex) else {
            return
        }

        let low = min(anchorIndex, currentIndex)
        let high = max(anchorIndex, currentIndex)
        appState.selection.selectedFiles = Set(images[low...high])
        finalizeRangeSelection(appState: appState, currentIndex: currentIndex, anchorIndex: anchorIndex, anchor: anchor)
    }

    private static func finalizeRangeSelection(
        appState: AppState,
        currentIndex: Int,
        anchorIndex: Int,
        anchor: Int?
    ) {
        let images = appState.fileData.displayedImages
        if currentIndex >= 0, currentIndex < images.count {
            appState.selection.mostRecentSelectedPath = images[currentIndex]
        }
        appState.selection.lastClickedIndex = currentIndex
        if anchor != nil {
            appState.selection.rangeAnchorIndex = anchor
        } else if appState.selection.rangeAnchorIndex == nil {
            appState.selection.rangeAnchorIndex = anchorIndex
        }
        appState.selection.emitSelectionChanged(highlightIndex: currentIndex)
    }

    static func toggleIndex(appState: AppState, index: Int) {
        let images = appState.fileData.displayedImages
        guard index >= 0, index < images.count else { return }
        let path = images[index]
        if appState.selection.selectedFiles.contains(path) {
            appState.selection.selectedFiles.remove(path)
        } else {
            appState.selection.selectedFiles.insert(path)
        }
        appState.fileData.setCurrentIndex(index)
        appState.fileData.setCurrentImagePath(path)
        appState.selection.mostRecentSelectedPath = path
        appState.selection.emitSelectionChanged(highlightIndex: index)
    }

    static func handleThumbnailClick(
        appState: AppState,
        index: Int,
        cmdPressed: Bool,
        shiftPressed: Bool,
        ctrlPressed: Bool
    ) {
        let images = appState.fileData.displayedImages
        guard index >= 0, index < images.count else { return }
        let path = images[index]

        appState.fileData.setCurrentIndex(index)
        appState.fileData.setCurrentImagePath(path)

        if shiftPressed {
            handleRangeSelection(appState: appState, currentIndex: index)
            return
        }

        if cmdPressed {
            selectThumbnail(appState: appState, index: index, addToSelection: true)
            return
        }

        if ctrlPressed {
            appState.selection.lastClickedIndex = index
            appState.selection.emitSelectionChanged(highlightIndex: index)
            return
        }

        clearSelection(appState: appState)
        selectThumbnail(appState: appState, index: index, addToSelection: false)
    }

    static func openBrowseForCurrentSelection(appState: AppState) {
        if appState.isLoadingDirectory {
            return
        }
        if openSelectedFilesLevel(appState: appState) {
            return
        }
        guard appState.fileData.currentImagePath != nil else { return }
        DisplayedImagesSync.ensureActiveImageListed(
            fileData: appState.fileData,
            filterPattern: appState.filterSettings.filterPattern,
            isLoadingDirectory: appState.isLoadingDirectory
        )
        if appState.fileData.currentViewMode == .list {
            appState.returnToListViewAfterBrowse = true
        }
        appState.fileData.setViewMode(.browse)
    }

    /// Port of Python ``navigation_manager.handle_thumbnail_click`` / ``_on_thumbnail_double_clicked``.
    /// Single-click opens browse when the preview pane is hidden; double-click opens when it is visible.
    static func openBrowseFromThumbnailActivation(
        appState: AppState,
        path: String? = nil,
        isDoubleClick: Bool
    ) {
        if isDoubleClick {
            guard appState.isPreviewPaneVisible else { return }
        } else {
            guard !appState.isPreviewPaneVisible else { return }
        }
        syncThumbnailPathForBrowseActivation(appState: appState, path: path)
        openBrowseForCurrentSelection(appState: appState)
    }

    private static func syncThumbnailPathForBrowseActivation(appState: AppState, path: String?) {
        guard let path,
              let index = appState.fileData.displayedImages.firstIndex(of: path),
              appState.fileData.currentImagePath != path else { return }
        clearSelection(appState: appState)
        selectThumbnail(appState: appState, index: index, addToSelection: false)
    }

    /// Return with multiple files selected — open a new specific-files level.
    @discardableResult
    static func openSelectedFilesLevel(appState: AppState) -> Bool {
        let selected = orderedSelectedFiles(appState: appState)
        guard selected.count > 1 else { return false }

        appState.directoryHistory.saveCurrent(
            fileData: appState.fileData,
            config: appState.config,
            selection: appState.selection
        )

        if appState.fileData.currentViewMode == .browse {
            appState.closeBrowseView()
        }

        let directory = URL(fileURLWithPath: selected[0]).deletingLastPathComponent().path
        appState.config.updateSetting("sort_mode", value: SortMode.custom.rawValue)
        appState.config.updateSetting("sort_reversed", value: false)
        appState.setSpecificFilesActive(true)
        appState.fileData.setCurrentDirectory(directory)
        appState.fileData.setDisplayedImages(selected)
        appState.fileData.setCurrentIndex(0)
        appState.fileData.setCurrentImagePath(selected[0])
        appState.fileData.setViewMode(.thumbnail)
        clearSelection(appState: appState)
        appState.eventBus.emit(.directoryLoaded, payload: .string(directory))
        appState.watchCurrentDirectory()
        return true
    }

    static func restoreSelections(appState: AppState, selectedFiles: [String]) {
        guard !selectedFiles.isEmpty else { return }

        let displayed = appState.fileData.displayedImages
        guard !displayed.isEmpty else { return }

        let saved = Set(selectedFiles)
        var restored = Set<String>()
        var lastSelectedIndex: Int?

        for (index, path) in displayed.enumerated() where saved.contains(path) {
            restored.insert(path)
            lastSelectedIndex = index
        }

        guard !restored.isEmpty else { return }

        appState.selection.selectedFiles = restored
        appState.selection.rangeAnchorIndex = nil
        appState.selection.resetCmdMulti()

        if let lastSelectedIndex {
            let path = displayed[lastSelectedIndex]
            appState.fileData.setCurrentIndex(lastSelectedIndex)
            appState.fileData.setCurrentImagePath(path)
            if !appState.selection.selectedFiles.contains(path) {
                appState.selection.selectedFiles.insert(path)
            }
            appState.selection.emitSelectionChanged(highlightIndex: lastSelectedIndex)
        } else {
            appState.selection.emitSelectionChanged()
        }
    }
}
