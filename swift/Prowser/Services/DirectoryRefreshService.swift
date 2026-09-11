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

    static func checkAndRefreshIfChanged(appState: AppState) {
        guard !appState.isDirectoryRefreshSuppressed else { return }
        guard !appState.specificFilesActive else { return }
        guard let directory = appState.fileData.currentDirectory,
              FileManager.default.fileExists(atPath: directory) else { return }

        let scanned = scannedDiskFiles(appState: appState)
        let diskSet = Set(scanned)
        let displayed = appState.fileData.displayedImages
        let displayedSet = Set(displayed)
        let rawAdded = diskSet.subtracting(displayedSet)
        let removed = displayedSet.subtracting(diskSet)
        let added = rawAdded.filter {
            !appState.imageGen.shouldSuppressGenerationOutputDiskUpdates(for: $0)
        }

        // In-progress step writes land on the job output path before the job finishes.
        if !rawAdded.isEmpty, added.isEmpty, removed.isEmpty {
            return
        }

        if diskSet == displayedSet || (added.isEmpty && removed.isEmpty) {
            if appState.fileData.currentViewMode == .browse {
                if let current = appState.fileData.currentImagePath,
                   appState.metadataCache.fileChangedOnDisk(path: current),
                   !appState.imageGen.shouldSuppressGenerationOutputDiskUpdates(for: current) {
                    invalidateThumbnails(appState: appState, paths: [current])
                    appState.reloadBrowseImageIfCurrent(path: current)
                }
                return
            }
            guard displayedSet.count < 500 else { return }
            let modified = modifiedPaths(in: displayedSet, metadataCache: appState.metadataCache)
                .filter { !appState.imageGen.shouldSuppressGenerationOutputDiskUpdates(for: $0) }
            if !modified.isEmpty {
                invalidateThumbnails(appState: appState, paths: modified)
            }
            return
        }

        let diskList = SortingService.sorted(
            scanned,
            options: SortingService.Options.from(config: appState.config),
            metadataCache: appState.metadataCache
        )
        efficientRefreshWithChanges(
            appState: appState,
            diskList: diskList,
            diskSet: Set(diskList),
            displayed: displayed,
            displayedSet: displayedSet,
            added: added,
            removed: removed
        )
    }

    private static func scannedDiskFiles(appState: AppState) -> [String] {
        guard let path = appState.fileData.currentDirectory else { return [] }
        return DirectoryScanner.scanDirectory(
            at: path,
            extensions: appState.config.imageExtensions,
            filterPattern: appState.filterSettings.filterPattern
        )
    }

    private static func modifiedPaths(
        in paths: Set<String>,
        metadataCache: MetadataCacheService
    ) -> [String] {
        paths.filter { metadataCache.fileChangedOnDisk(path: $0) }
    }

    private static func efficientRefreshWithChanges(
        appState: AppState,
        diskList: [String],
        diskSet: Set<String>,
        displayed: [String],
        displayedSet: Set<String>,
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
        removeDisplayedFiles(
            appState: appState,
            removed: removed,
            displayed: displayed,
            activePath: activePath
        )
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

    static func invalidateThumbnails(appState: AppState, paths: [String]) {
        guard !paths.isEmpty else { return }
        for path in paths {
            appState.metadataCache.invalidate(path: path)
        }
        let cache = appState.thumbnailCache
        Task {
            for path in paths {
                await cache.invalidate(for: path)
            }
        }
        appState.thumbnailInvalidationGeneration += 1
        appState.eventBus.emit(.thumbnailsInvalidated, payload: .strings(paths))
        for path in paths {
            appState.metadataCache.recordDiskSnapshot(path: path)
        }
    }
}
