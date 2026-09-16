import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension AppState {
    func observeViewModeChanges() {
        _ = NotificationCenter.default.addObserver(
            forName: .prowserViewModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else { return }
                let raw = notification.object as? String ?? ""
                let newMode = ViewMode(rawValue: raw) ?? .thumbnail
                self.handleViewModeTransition(to: newMode)
            }
        }
    }

    func handleViewModeTransition(to newMode: ViewMode) {
        refreshMenuState()
        let previous = lastViewMode
        if previous != .browse && newMode == .browse {
            prepareBrowseReturnStateIfNeeded()
        }
        if previous == .browse && newMode == .thumbnail {
            restoreBrowseReturnStateIfNeeded()
        }
        lastViewMode = newMode
    }

    /// Drop stashed thumbnail context so exiting browse uses the current directory listing.
    func clearBrowseReturnState() {
        browseReturnThumbnailState = nil
    }

    func prepareBrowseReturnStateIfNeeded() {
        guard browseReturnThumbnailState == nil else { return }
        guard shouldStashThumbnailContextForBrowse() else { return }
        browseReturnThumbnailState = BrowseReturnThumbnailState(
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
        if config.string(forKey: "sort_mode", default: "date") == SortMode.custom.rawValue {
            return true
        }
        return false
    }

    func restoreBrowseReturnStateIfNeeded() {
        guard let stashed = browseReturnThumbnailState else { return }
        browseReturnThumbnailState = nil
        config.updateSetting("sort_mode", value: stashed.sortMode)
        config.updateSetting("sort_reversed", value: stashed.sortReversed)
        if let directory = stashed.currentDirectory {
            fileData.setCurrentDirectory(directory)
        }
        setSpecificFilesActive(stashed.specificFilesActive)
        fileData.setDisplayedImages(stashed.displayedImages)
        if let path = stashed.currentImagePath {
            fileData.setCurrentImagePath(path)
        } else {
            fileData.setCurrentIndex(stashed.currentIndex)
        }
        config.updateSetting("thumbnail_cell_size", value: stashed.thumbnailCellSize)
        config.updateSetting("manual_thumbnail_size", value: stashed.manualThumbnailSize)
        config.applySettingsChange(emit: eventBus)
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
            DisplayedImagesSync.ensureActiveImageListed(fileData: fileData)
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
