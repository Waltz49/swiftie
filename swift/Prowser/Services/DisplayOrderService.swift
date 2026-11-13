import Foundation

/// Display ordering with locked files pinned first. Port of `sorting_manager.apply_display_order`.
@MainActor
enum DisplayOrderService {
    struct DisplayOrderResult {
        var paths: [String]
        var duplicateHashGroups: DuplicateHashService.HashGroups?
    }

    static func applyDisplayOrder(
        _ images: [String],
        appState: AppState,
        skipLocks: Bool? = nil,
        commentRanks: [String: Int]? = nil,
        trustPreSortedFromDirectoryLoad: Bool = false,
        precomputedDuplicateHashGroups: DuplicateHashService.HashGroups? = nil
    ) -> [String] {
        applyDisplayOrderWithContext(
            images,
            appState: appState,
            skipLocks: skipLocks,
            commentRanks: commentRanks,
            trustPreSortedFromDirectoryLoad: trustPreSortedFromDirectoryLoad,
            precomputedDuplicateHashGroups: precomputedDuplicateHashGroups
        ).paths
    }

    static func applyDisplayOrderWithContext(
        _ images: [String],
        appState: AppState,
        skipLocks: Bool? = nil,
        commentRanks: [String: Int]? = nil,
        trustPreSortedFromDirectoryLoad: Bool = false,
        precomputedDuplicateHashGroups: DuplicateHashService.HashGroups? = nil
    ) -> DisplayOrderResult {
        guard !images.isEmpty else {
            return DisplayOrderResult(paths: [], duplicateHashGroups: nil)
        }

        let skip: Bool
        if let skipLocks {
            skip = skipLocks
        } else {
            switch appState.fileData.currentViewMode {
            case .list, .slideshow, .slideshow2, .slideshow3:
                skip = true
            default:
                skip = false
            }
        }

        let options = SortingService.Options.from(config: appState.config)
        let ranks = commentRanks ?? (options.mode == .comments ? appState.listViewHost?.commentColumnSortRanks() : nil)

        if skip {
            let sorted = SortingService.sortedWithDuplicateContext(
                images,
                options: options,
                metadataCache: appState.metadataCache,
                commentRanks: ranks
            )
            return DisplayOrderResult(paths: sorted.paths, duplicateHashGroups: sorted.duplicateHashGroups)
        }

        let (locked, unlocked) = PrsortIO.separateLockedUnlocked(images)
        if locked.isEmpty {
            if trustPreSortedFromDirectoryLoad {
                return DisplayOrderResult(
                    paths: images,
                    duplicateHashGroups: precomputedDuplicateHashGroups
                )
            }
            let sorted = SortingService.sortedWithDuplicateContext(
                images,
                options: options,
                metadataCache: appState.metadataCache,
                commentRanks: ranks
            )
            return DisplayOrderResult(paths: sorted.paths, duplicateHashGroups: sorted.duplicateHashGroups)
        }

        let directory = (images[0] as NSString).deletingLastPathComponent
        if trustPreSortedFromDirectoryLoad,
           options.mode == .duplicates,
           precomputedDuplicateHashGroups != nil {
            return DisplayOrderResult(
                paths: locked + unlocked,
                duplicateHashGroups: precomputedDuplicateHashGroups
            )
        }

        let sortedUnlocked: (paths: [String], duplicateHashGroups: DuplicateHashService.HashGroups?)
        if options.mode == .custom {
            sortedUnlocked = (PrsortIO.applyCustomSortUnlocked(unlocked, directory: directory), nil)
        } else {
            sortedUnlocked = SortingService.sortedWithDuplicateContext(
                unlocked,
                options: options,
                metadataCache: appState.metadataCache,
                commentRanks: ranks
            )
        }
        return DisplayOrderResult(
            paths: locked + sortedUnlocked.paths,
            duplicateHashGroups: sortedUnlocked.duplicateHashGroups
        )
    }
}
