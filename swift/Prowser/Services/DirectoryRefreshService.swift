import Foundation

/// Efficient directory refresh on disk changes. Port of `refresh_manager.py`.
@MainActor
enum DirectoryRefreshService {
    static func shouldWatchDirectory(appState: AppState) -> Bool {
        if appState.specificFilesActive { return false }
        guard let directory = appState.fileData.currentDirectory else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        let displayed = appState.fileData.displayedImages
        if displayed.isEmpty { return true }
        let currentDir = URL(fileURLWithPath: directory).standardizedFileURL.path
        return displayed.allSatisfy { path in
            URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path == currentDir
        }
    }

    /// Refresh the displayed specific-files set (Python `_refresh_specific_files_list`).
    static func refreshSpecificFilesList(appState: AppState, force: Bool = false) {
        let displayed = appState.fileData.displayedImages
        guard !displayed.isEmpty else { return }

        let activePath = appState.fileData.currentImagePath
        let validFiles = displayed.filter { FileManager.default.fileExists(atPath: $0) }
        let deleted = Set(displayed).subtracting(validFiles)

        if validFiles.isEmpty {
            appState.fileData.setDisplayedImages([])
            appState.fileData.setCurrentImagePath(nil)
            appState.thumbnailGridHost?.clearThumbnails()
            return
        }

        if !deleted.isEmpty {
            applyRemovedFiles(
                appState: appState,
                removed: deleted,
                displayed: displayed,
                activePath: activePath
            )
        }

        let currentList = appState.fileData.displayedImages
        if let activePath, currentList.contains(activePath) {
            appState.fileData.setCurrentImagePath(activePath)
        } else if let first = currentList.first {
            appState.fileData.setCurrentImagePath(first)
        }

        if force {
            invalidateThumbnails(appState: appState, paths: currentList)
        } else {
            let modified = modifiedPaths(in: Set(currentList), metadataCache: appState.metadataCache)
            if !modified.isEmpty {
                invalidateThumbnails(appState: appState, paths: modified)
            }
        }

        appState.thumbnailGridHost?.startBackgroundThumbnailLoadingIfNeeded()
    }

    static func checkAndRefreshIfChanged(appState: AppState) {
        guard !appState.isLoadingDirectory else { return }
        guard !appState.isDirectoryRefreshSuppressed else { return }
        if appState.specificFilesActive {
            refreshSpecificFilesList(appState: appState, force: false)
            return
        }
        guard let directory = appState.fileData.currentDirectory,
              FileManager.default.fileExists(atPath: directory) else { return }

        let extensions = appState.config.imageExtensions
        let filterPattern = appState.filterSettings.filterPattern
        Task { @MainActor in
            let scanned = await Task.detached(priority: .utility) {
                DirectoryScanner.scanDirectory(
                    at: directory,
                    extensions: extensions,
                    filterPattern: filterPattern
                )
            }.value
            guard appState.fileData.currentDirectory == directory else { return }

            let displayed = appState.fileData.displayedImages
            let diskSet = Set(scanned)
            let displayedSet = Set(displayed)
            let rawAdded = diskSet.subtracting(displayedSet)
            var removed = displayedSet.subtracting(diskSet)
            removed.subtract(filterOnlyRemovals(from: removed, appState: appState))
            let added = rawAdded

            if diskSet == displayedSet || (added.isEmpty && removed.isEmpty) {
                if ThumbnailLockOrdering.applyLockFirstOrderIfNeeded(appState: appState) {
                    return
                }
                if appState.fileData.currentViewMode == .browse {
                    if let current = appState.fileData.currentImagePath,
                       !appState.imageGen.shouldSuppressGenerationOutputDiskUpdates(for: current),
                       appState.metadataCache.fileChangedOnDisk(path: current) {
                        invalidateThumbnails(appState: appState, paths: [current])
                        appState.reloadBrowseImageIfCurrent(path: current)
                    }
                    return
                }
                guard displayedSet.count < 500 else { return }
                let modified = modifiedPaths(in: displayedSet, metadataCache: appState.metadataCache)
                if !modified.isEmpty {
                    invalidateThumbnails(appState: appState, paths: modified)
                }
                return
            }

            efficientRefreshWithChanges(
                appState: appState,
                displayed: displayed,
                added: added,
                removed: removed
            )
        }
    }

    /// Paths still on disk but absent from a filtered scan (inserted for the active image).
    private static func filterOnlyRemovals(from removed: Set<String>, appState: AppState) -> Set<String> {
        guard !removed.isEmpty,
              let active = appState.fileData.currentImagePath else { return [] }
        let activeNorm = URL(fileURLWithPath: active).standardizedFileURL.path
        return removed.filter { path in
            guard FileManager.default.fileExists(atPath: path) else { return false }
            return URL(fileURLWithPath: path).standardizedFileURL.path == activeNorm
        }
    }

    private static func modifiedPaths(
        in paths: Set<String>,
        metadataCache: MetadataCacheService
    ) -> [String] {
        paths.filter { metadataCache.fileChangedOnDisk(path: $0) }
    }

    private static func efficientRefreshWithChanges(
        appState: AppState,
        displayed: [String],
        added: Set<String>,
        removed: Set<String>
    ) {
        if !removed.isEmpty && added.isEmpty {
            if appState.fileData.currentViewMode == .browse {
                let preserved = appState.fileData.currentImagePath
                let newList = displayed.filter { !removed.contains($0) }
                appState.fileData.setDisplayedImages(newList)
                if let preserved, newList.contains(preserved) {
                    appState.fileData.setCurrentImagePath(preserved)
                } else if let first = newList.first {
                    appState.fileData.setCurrentImagePath(first)
                }
                noteIdleBackgroundScanScopeChanged(appState: appState)
            } else {
                removeDisplayedFiles(appState: appState, removed: removed, displayed: displayed)
            }
            return
        }

        guard let directory = appState.fileData.currentDirectory else { return }
        appState.loadDirectory(directory, saveHistory: false)
    }

    /// Remove deleted paths from the displayed list and advance the active image (Python `remove_thumbnails_for_files`).
    static func applyRemovedFiles(
        appState: AppState,
        removed: Set<String>,
        displayed: [String],
        activePath: String?
    ) {
        guard !removed.isEmpty else { return }
        if appState.isFormattedListMode() {
            let placeholders = removed.filter { displayed.contains($0) }
            if !placeholders.isEmpty {
                appState.addDeletedPlaceholders(Set(placeholders))
            }
            advanceActiveAfterDeletion(
                appState: appState,
                original: displayed,
                removed: removed,
                activePath: activePath
            )
            return
        }
        removeDisplayedFiles(
            appState: appState,
            removed: removed,
            displayed: displayed,
            activePath: activePath
        )
    }

    private static func advanceActiveAfterDeletion(
        appState: AppState,
        original: [String],
        removed: Set<String>,
        activePath: String?
    ) {
        let priorActivePath = activePath ?? appState.fileData.currentImagePath
        if let priorActivePath, !removed.contains(priorActivePath) {
            appState.fileData.setCurrentImagePath(priorActivePath)
        } else if let next = nextImageAfterDeletion(
            original: original,
            removed: removed,
            activePath: priorActivePath
        ) {
            appState.fileData.setCurrentImagePath(next)
        } else if let first = original.first {
            appState.fileData.setCurrentImagePath(first)
        }
    }

    private static func removeDisplayedFiles(
        appState: AppState,
        removed: Set<String>,
        displayed: [String],
        activePath: String? = nil
    ) {
        let priorActivePath = activePath ?? appState.fileData.currentImagePath
        let newList = displayed.filter { !removed.contains($0) }
        appState.fileData.setDisplayedImages(newList)

        if let priorActivePath, newList.contains(priorActivePath), !removed.contains(priorActivePath) {
            appState.fileData.setCurrentImagePath(priorActivePath)
        } else {
            let next = nextImageAfterDeletion(
                original: displayed,
                removed: removed,
                activePath: priorActivePath
            )
            if let next {
                appState.fileData.setCurrentImagePath(next)
            } else if let first = newList.first {
                appState.fileData.setCurrentImagePath(first)
            } else {
                appState.fileData.setCurrentImagePath(nil)
            }
        }

        invalidateThumbnails(appState: appState, paths: Array(removed))

        let sortMode = SortMode(rawValue: appState.config.string(forKey: "sort_mode", default: "date")) ?? .date
        if sortMode == .duplicates {
            appState.applyCurrentSort()
        }
    }

    private static func nextImageAfterDeletion(
        original: [String],
        removed: Set<String>,
        activePath: String?
    ) -> String? {
        guard let activePath else {
            return original.first { !removed.contains($0) }
        }
        if let index = original.firstIndex(of: activePath) {
            for candidate in original[(index + 1)...] where !removed.contains(candidate) {
                return candidate
            }
            for candidate in original[..<index].reversed() where !removed.contains(candidate) {
                return candidate
            }
        }
        return original.first { !removed.contains($0) }
    }

    /// Invalidate idle background scan state when displayed paths or file content change.
    private static func noteIdleBackgroundScanScopeChanged(appState: AppState) {
        appState.backgroundImageRecognition.noteIdleScanScopeChanged()
    }

    /// Light refresh when directory listing is unchanged (⌘R) — avoid O(n) main-thread stats + full pixmap drop.
    static func refreshThumbnailPresentation(appState: AppState) {
        appState.thumbnailInvalidationGeneration += 1
        appState.thumbnailGridHost?.startBackgroundThumbnailLoadingIfNeeded()
        appState.thumbnailGridHost?.setNeedsDisplay(appState.thumbnailGridHost?.bounds ?? .zero)
    }

    static func invalidateThumbnails(appState: AppState, paths: [String]) {
        let paths = paths.filter {
            !appState.imageGen.shouldSuppressGenerationOutputDiskUpdates(for: $0)
        }
        guard !paths.isEmpty else { return }
        for path in paths {
            appState.metadataCache.invalidate(path: path)
            appState.previewPaneCache.invalidate(path: path)
        }
        appState.backgroundImageRecognition.noteThumbnailDiskCacheInvalidated()
        appState.thumbnailInvalidationGeneration += 1
        appState.eventBus.emit(.thumbnailsInvalidated, payload: .strings(paths))

        let cache = appState.thumbnailCache
        let pathsCopy = paths
        Task {
            for path in pathsCopy {
                await cache.invalidate(for: path)
            }
            _ = await cache.removeDiskThumbnails(for: pathsCopy)
            await MainActor.run {
                refreshPreviewAndBrowseIfCurrentImageChanged(appState: appState, paths: pathsCopy)
                for path in pathsCopy {
                    appState.metadataCache.recordDiskSnapshot(path: path)
                }
            }
        }
    }

    private static func refreshPreviewAndBrowseIfCurrentImageChanged(appState: AppState, paths: [String]) {
        guard let current = appState.fileData.currentImagePath else { return }
        guard paths.contains(where: { FileDataModel.pathsReferToSameFile($0, current) }) else { return }
        appState.previewPaneContentRevision += 1
        appState.reloadBrowseImageIfCurrent(path: current)
    }

}
