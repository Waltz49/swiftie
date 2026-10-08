import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension AppState {
    func observeViewModeChanges() {
        _ = eventBus.subscribe(.viewModeChanged) { [weak self] event in
            guard let self, case .string(let raw) = event.payload else { return }
            let newMode = ViewMode(rawValue: raw) ?? .thumbnail
            self.handleViewModeTransition(to: newMode)
        }
    }

    func handleViewModeTransition(to newMode: ViewMode) {
        let previous = lastViewMode
        let enteringBrowse = previous != .browse && newMode == .browse
        let leavingBrowse = previous == .browse && (newMode == .thumbnail || newMode == .list)

        if enteringBrowse {
            if previous == .list {
                returnToListViewAfterBrowse = true
            }
            prepareBrowseReturnStateIfNeeded()
            primeMenuKeysForViewChange()
            DispatchQueue.main.async { [weak self] in
                self?.focusMainCanvas()
            }
        } else if leavingBrowse {
            refreshMenuState()
            clearUserRequestedTreeDirectory()
            let browseExitPath = fileData.currentImagePath
            if newMode == .thumbnail {
                restoreBrowseReturnStateIfNeeded()
            } else {
                browseReturnThumbnailState = nil
            }
            ensureCurrentDirectoryAlignedWithActiveImage()
            reconcileUserRequestedTreeDirectoryWithActiveImage()
            if newMode == .thumbnail {
                finalizeThumbnailHighlightAfterBrowseExit(preferredPath: browseExitPath)
                scheduleScrollThumbnailGridToActiveImageAfterLayout()
            }
            syncFileTreeToActiveImage()
            focusMainCanvas()
        } else {
            refreshMenuState()
        }
        lastViewMode = newMode
    }

    /// Drop a stale tree pin when browse navigation moved the active image to another folder.
    func reconcileUserRequestedTreeDirectoryWithActiveImage() {
        guard let requested = userRequestedTreeDirectory,
              !specificFilesActive,
              let path = fileData.currentImagePath else { return }
        let imageDir = FileTreeFilter.standardizedPath(
            URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
        )
        if imageDir != FileTreeFilter.standardizedPath(requested) {
            clearUserRequestedTreeDirectory()
        }
    }

    /// Drop stashed thumbnail context so exiting browse uses the current directory listing.
    func clearBrowseReturnState() {
        browseReturnThumbnailState = nil
    }

    func prepareBrowseReturnStateIfNeeded() {
        guard browseReturnThumbnailState == nil else { return }
        guard shouldStashThumbnailContextForBrowse() else { return }
        browseReturnThumbnailState = currentBrowseReturnSnapshot()
    }

    /// Push the current folder before opening an image in a different one.
    /// Esc from that browse stays in the new folder; the next Esc (thumbnail) returns here.
    func displaceCurrentLevelIfOpeningNewDirectory(_ path: String) {
        guard let newDirectory = FileDataModel.parentDirectory(of: path) else { return }
        let newNorm = FileDataModel.normalizePath(newDirectory) ?? newDirectory
        guard thumbnailContextWouldChange(forNewDirectory: newNorm) else { return }
        directoryHistory.saveCurrent(fileData: fileData, config: config, selection: selection)
    }

    /// Python `thumbnail_context_would_change`: specific-files / reference graph, or a different folder.
    func thumbnailContextWouldChange(forNewDirectory newDirectory: String) -> Bool {
        if specificFilesActive || referenceGraphActive { return true }
        let newNorm = FileDataModel.normalizePath(newDirectory) ?? newDirectory
        if let current = fileData.currentDirectory,
           let currentNorm = FileDataModel.normalizePath(current),
           currentNorm != newNorm {
            return true
        }
        if let first = fileData.displayedImages.first,
           let shown = FileDataModel.parentDirectory(of: first),
           shown != newNorm {
            return true
        }
        return false
    }

    private func currentBrowseReturnSnapshot() -> BrowseReturnThumbnailState {
        BrowseReturnThumbnailState(
            displayedImages: fileData.displayedImages,
            currentIndex: fileData.currentIndex,
            currentImagePath: fileData.currentImagePath,
            currentDirectory: fileData.currentDirectory,
            specificFilesActive: specificFilesActive,
            sortMode: config.string(forKey: "sort_mode", default: "date"),
            sortReversed: config.bool(forKey: "sort_reversed", default: false),
            thumbnailCellSize: config.double(forKey: "thumbnail_cell_size", default: ThumbnailLayout.defaultCellSize),
            manualThumbnailSize: config.bool(forKey: "manual_thumbnail_size", default: false)
        )
    }

    func shouldStashThumbnailContextForBrowse() -> Bool {
        if specificFilesActive { return true }
        if referenceGraphActive { return true }
        if config.string(forKey: "sort_mode", default: "date") == SortMode.custom.rawValue {
            return true
        }
        if let path = fileData.currentImagePath,
           let imageDir = FileDataModel.parentDirectory(of: path),
           let currentDir = fileData.currentDirectory {
            let imageNorm = URL(fileURLWithPath: imageDir).standardizedFileURL.path
            let currentNorm = URL(fileURLWithPath: currentDir).standardizedFileURL.path
            if imageNorm != currentNorm {
                return true
            }
        }
        return false
    }

    func restoreBrowseReturnStateIfNeeded() {
        guard let stashed = browseReturnThumbnailState else { return }
        browseReturnThumbnailState = nil
        let pathAtBrowseExit = fileData.currentImagePath
        config.updateSetting("sort_mode", value: stashed.sortMode)
        config.updateSetting("sort_reversed", value: stashed.sortReversed)
        if let directory = stashed.currentDirectory {
            fileData.setCurrentDirectory(directory)
        }
        setSpecificFilesActive(stashed.specificFilesActive)
        fileData.setDisplayedImages(stashed.displayedImages)
        let restoredPath = Self.resolveActiveImagePathAfterBrowseRestore(
            preferred: pathAtBrowseExit,
            fallback: stashed.currentImagePath,
            in: fileData.displayedImages
        )
        if let restoredPath {
            fileData.setCurrentImagePath(restoredPath)
        }
        config.updateSetting("thumbnail_cell_size", value: stashed.thumbnailCellSize)
        config.updateSetting("manual_thumbnail_size", value: stashed.manualThumbnailSize)
        config.applySettingsChange(emit: eventBus)
        finalizeThumbnailHighlightAfterBrowseExit(preferredPath: restoredPath ?? pathAtBrowseExit)
    }

    /// Pick the active file by path after restoring a stashed thumbnail list. Never uses list indices.
    private static func resolveActiveImagePathAfterBrowseRestore(
        preferred: String?,
        fallback: String?,
        in displayedImages: [String]
    ) -> String? {
        for candidate in [preferred, fallback] {
            guard let candidate,
                  let normalized = FileDataModel.normalizePath(candidate),
                  FileDataModel.indexOfPath(normalized, in: displayedImages) != nil else { continue }
            return normalized
        }
        return nil
    }

    /// Python ``highlight_image`` / ``ensure_highlighted_visible`` after browse exit or history restore.
    func scrollThumbnailGridToActiveImageAfterLayout() {
        guard fileData.currentViewMode == .thumbnail else { return }
        fileData.reconcileCurrentIndexWithPath()
        guard let grid = thumbnailGridHost else { return }
        let paths = fileData.displayedImages
        guard !paths.isEmpty,
              let path = fileData.currentImagePath,
              let normalized = FileDataModel.normalizePath(path),
              let index = FileDataModel.indexOfPath(normalized, in: paths) else { return }

        grid.referenceGraph = referenceGraphActive ? referenceGraphData : nil
        let scroll = { [weak grid] in
            guard let grid else { return }
            grid.reloadLayoutIfNeeded()
            grid.selectIndex(index, scroll: true, notifyDelegate: false)
            grid.scrollToSelectionAfterLayout()
        }
        scroll()
    }

    /// Defer scroll until after layout/settings subscribers run (splitter, reference graph layout).
    func scheduleScrollThumbnailGridToActiveImageAfterLayout() {
        DispatchQueue.main.async { [weak self] in
            self?.scrollThumbnailGridToActiveImageAfterLayout()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.scrollThumbnailGridToActiveImageAfterLayout()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.scrollThumbnailGridToActiveImageAfterLayout()
        }
    }

    /// Re-highlight the browse exit file by path (never by stale list index).
    func finalizeThumbnailHighlightAfterBrowseExit(preferredPath: String?) {
        guard fileData.currentViewMode == .thumbnail else { return }
        let candidates = [preferredPath, fileData.currentImagePath].compactMap { $0 }
        for raw in candidates {
            guard let path = FileDataModel.normalizePath(raw) else { continue }
            DisplayedImagesSync.ensureActiveImageListed(
                fileData: fileData,
                filterPattern: filterSettings.filterPattern
            )
            if FileDataModel.indexOfPath(path, in: fileData.displayedImages) != nil {
                fileData.setCurrentImagePath(path)
                fileData.reconcileCurrentIndexWithPath()
                return
            }
        }
    }
    /// Python launch restore: thumbnail/slideshow reopen the folder, browse reopens the file.
    func restoreSession(_ snapshot: AppConfig.RestoreStateSnapshot) {
        let mode = ViewMode(rawValue: snapshot.lastViewMode) ?? .thumbnail
        let directory = snapshot.lastDirectory.flatMap { path in
            FileManager.default.fileExists(atPath: path) ? path : nil
        } ?? snapshot.lastFile.flatMap { FileDataModel.parentDirectory(of: $0) }

        let listModes: Set<ViewMode> = [.thumbnail, .list, .slideshow, .slideshow2, .slideshow3]
        if listModes.contains(mode) {
            if let directory, FileManager.default.fileExists(atPath: directory) {
                loadDirectory(directory, saveHistory: false)
            }
        } else if let file = snapshot.lastFile, FileManager.default.fileExists(atPath: file) {
            openPaths([file])
        } else if let directory, FileManager.default.fileExists(atPath: directory) {
            loadDirectory(directory, saveHistory: false)
        }

        if let file = snapshot.lastFile, FileManager.default.fileExists(atPath: file) {
            fileData.setCurrentImagePath(file)
            DisplayedImagesSync.ensureActiveImageListed(
                fileData: fileData,
                filterPattern: filterSettings.filterPattern
            )
            if PhotosLibraryBrowseLoader.isPhotosLibraryPath(file) {
                _ = PhotosLibraryBrowseLoader.requestAccessIfNeeded(for: file)
            }
        }
        fileData.setViewMode(mode)
    }

    func persistRestoreState(enableLaunchRestore: Bool = false) {
        let path = fileData.currentImagePath
        let directory = fileData.currentDirectory
        guard path != nil || directory != nil else { return }
        if enableLaunchRestore {
            config.saveRestoreState(
                filePath: path,
                directory: directory,
                viewMode: fileData.currentViewMode.rawValue,
                macosSpaceMode: WindowFullscreen.macOSSpaceModeForRestore()
            )
        } else {
            config.updateRestoreSnapshot(
                filePath: path,
                directory: directory,
                viewMode: fileData.currentViewMode.rawValue,
                macosSpaceMode: WindowFullscreen.macOSSpaceModeForRestore()
            )
        }
    }
}
