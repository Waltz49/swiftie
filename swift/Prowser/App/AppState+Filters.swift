import Foundation

extension AppState {
    func setFileTreeFilterMode(_ mode: String) {
        filterSettings.setFilteredTree(mode)
        refreshFileTreeFilter()
        config.applySettingsChange(emit: eventBus, affectsDirectoryListing: false)
    }

    func applyFilenameFilterPattern(_ pattern: String) {
        let previousPattern = filterSettings.filterPattern
        filterSettings.setFilterPattern(pattern, persist: true)
        guard filterSettings.filterPattern != previousPattern else { return }
        let listingSubsetApplied = applyImmediateFilenameFilterToDisplayedImages()
        refreshFileTreeFilterShallow()
        if filterSettings.filterPattern == "*" || !listingSubsetApplied {
            refreshDirectory()
        }
        config.applySettingsChange(emit: eventBus, affectsDirectoryListing: false)
    }

    /// Subset the current listing by the active glob (Python `filter_images_by_pattern`) before the async rescan finishes.
    @discardableResult
    private func applyImmediateFilenameFilterToDisplayedImages() -> Bool {
        let pattern = filterSettings.filterPattern
        let current = fileData.displayedImages
        guard !current.isEmpty else { return false }

        if referenceGraphActive, !specificFilesActive {
            return false
        }

        let filtered = current.filter { path in
            let basename = (path as NSString).lastPathComponent
            return DirectoryScanner.matchesGlob(basename, pattern: pattern)
        }

        guard filtered != current else { return false }

        let priorActive = fileData.currentImagePath
        let ordered = DisplayOrderService.applyDisplayOrder(filtered, appState: self)
        fileData.setDisplayedImages(ordered)

        if let priorActive, ordered.contains(priorActive) {
            fileData.setCurrentImagePath(priorActive)
        } else if let priorActive, let index = current.firstIndex(of: priorActive) {
            let next = current[(index + 1)...].first(where: { ordered.contains($0) })
                ?? current[..<index].reversed().first(where: { ordered.contains($0) })
                ?? ordered.first
            fileData.setCurrentImagePath(next)
        } else {
            fileData.setCurrentImagePath(ordered.first)
        }

        let sortMode = SortMode(rawValue: config.string(forKey: "sort_mode", default: "date")) ?? .date
        if sortMode == .duplicates {
            applyCurrentSort()
        }

        DirectoryRefreshService.reconcileThumbnailGridListing(appState: self)
        return true
    }

    func refreshFileTreeFilter() {
        FileTreeFilter.invalidateCache()
        fileTreeReloadFilterOnly = true
        fileTreeReloadPreservesExpansion = true
        fileTreeReloadToken += 1
    }

    /// Listing glob changed; tree `shouldShowDirectory` refreshes its own cache key without wiping deep discovery.
    func refreshFileTreeFilterShallow() {
        FileTreeFilter.invalidateShallowFilterCache()
        fileTreeReloadFilterOnly = true
        fileTreeReloadPreservesExpansion = true
        fileTreeReloadToken += 1
    }

    /// After preferences OK when directories, filters, or extensions changed — rebuild tree, keep expansion/highlight.
    func refreshFileTreeAfterSettingsCommit() {
        filterSettings.loadFromConfig()
        FileTreeFilter.invalidateCache()
        fileTreeReloadPreservesExpansion = true
        fileTreeReloadToken += 1
    }
}
