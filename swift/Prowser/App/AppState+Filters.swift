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
        fileTreeReloadToken += 1
    }
}
