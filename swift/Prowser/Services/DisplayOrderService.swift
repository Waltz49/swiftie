import Foundation

/// Display ordering with locked files pinned first. Port of `sorting_manager.apply_display_order`.
@MainActor
enum DisplayOrderService {
    static func applyDisplayOrder(
        _ images: [String],
        appState: AppState,
        skipLocks: Bool? = nil,
        commentRanks: [String: Int]? = nil
    ) -> [String] {
        guard !images.isEmpty else { return [] }

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
            return SortingService.sorted(
                images,
                options: options,
                metadataCache: appState.metadataCache,
                commentRanks: ranks
            )
        }

        let (locked, unlocked) = PrsortIO.separateLockedUnlocked(images)
        if locked.isEmpty {
            return SortingService.sorted(
                images,
                options: options,
                metadataCache: appState.metadataCache,
                commentRanks: ranks
            )
        }

        let directory = (images[0] as NSString).deletingLastPathComponent
        let sortedUnlocked: [String]
        if options.mode == .custom {
            sortedUnlocked = PrsortIO.applyCustomSortUnlocked(unlocked, directory: directory)
        } else {
            sortedUnlocked = SortingService.sorted(
                unlocked,
                options: options,
                metadataCache: appState.metadataCache,
                commentRanks: ranks
            )
        }
        return locked + sortedUnlocked
    }
}
