import Foundation

/// Lightweight lock pinning when the file set is unchanged (no full re-sort).
/// Full sort / directory load uses `DisplayOrderService.applyDisplayOrder` instead.
@MainActor
enum ThumbnailLockOrdering {
    static func enforceLockedFirstInThumbnailView(appState: AppState) -> Bool {
        guard appState.fileData.currentViewMode == .thumbnail else { return false }
        guard !appState.specificFilesActive else { return false }
        guard appState.config.bool(forKey: "allow_thumbnail_locking", default: false) else { return false }
        let raw = appState.config.string(forKey: "sort_mode", default: SortMode.date.rawValue)
        if raw == SortMode.custom.rawValue { return false }
        return true
    }

    static func needsLockedFilesFirst(images: [String], appState: AppState) -> Bool {
        guard !images.isEmpty, enforceLockedFirstInThumbnailView(appState: appState) else { return false }
        let (locked, _) = PrsortIO.separateLockedUnlocked(images)
        guard !locked.isEmpty else { return false }
        return Array(images.prefix(locked.count)) != locked
    }

    static func reorderLockedFilesFirst(_ images: [String]) -> [String] {
        let (locked, unlocked) = PrsortIO.separateLockedUnlocked(images)
        guard !locked.isEmpty else { return images }
        return locked + unlocked
    }

    /// Pin locked files to the top in `.prsort` order without re-sorting unlocked files.
    /// Returns true when `displayedImages` was updated.
    @discardableResult
    static func applyLockFirstOrderIfNeeded(appState: AppState) -> Bool {
        let images = appState.fileData.displayedImages
        guard needsLockedFilesFirst(images: images, appState: appState) else { return false }
        let ordered = reorderLockedFilesFirst(images)
        guard ordered != images else { return false }
        appState.fileData.setDisplayedImages(ordered)
        return true
    }
}
