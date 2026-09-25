import Foundation

extension AppState {
    func setFileTreeFilterMode(_ mode: String) {
        filterSettings.setFilteredTree(mode)
        refreshFileTreeFilter()
        config.applySettingsChange(emit: eventBus)
    }

    func applyFilenameFilterPattern(_ pattern: String) {
        filterSettings.setFilterPattern(pattern, persist: true)
        refreshFileTreeFilter()
        refreshDirectory()
        config.applySettingsChange(emit: eventBus)
    }

    func refreshFileTreeFilter() {
        FileTreeFilter.invalidateCache()
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
