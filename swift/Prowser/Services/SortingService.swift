import Foundation

/// Sorts displayed image paths. Port of `sorting_manager.py` (core modes).
@MainActor
enum SortingService {
    struct Options {
        var mode: SortMode
        var reversed: Bool
        var useExifDate: Bool

        @MainActor
        static func from(config: AppConfig) -> Options {
            let raw = config.rawSettings()["sort_mode"] as? String ?? "date"
            let mode = SortMode(rawValue: raw) ?? .date
            let reversed = config.rawSettings()["sort_reversed"] as? Bool ?? false
            return Options(mode: mode, reversed: reversed, useExifDate: config.useExifDate)
        }
    }

    /// Sorted paths plus duplicate hash groups when `options.mode == .duplicates`.
    static func sortedWithDuplicateContext(
        _ paths: [String],
        options: Options,
        metadataCache: MetadataCacheService? = nil,
        commentRanks: [String: Int]? = nil
    ) -> (paths: [String], duplicateHashGroups: DuplicateHashService.HashGroups?) {
        let kernelOptions = ImagePathSortingKernel.Options(
            mode: options.mode,
            reversed: options.reversed,
            useExifDate: options.useExifDate
        )
        let metadata: MetadataCacheSnapshot = if let metadataCache {
            MetadataCacheSnapshot.forSorting(
                diskCacheFilePath: metadataCache.persistedCacheFilePath,
                liveMemory: metadataCache.sortingSnapshot()
            )
        } else {
            MetadataCacheSnapshot(entries: [:])
        }
        let ranks = resolvedCommentRanks(paths: paths, options: options, commentRanks: commentRanks)
        let output = ImagePathSortingKernel.sort(
            paths,
            options: kernelOptions,
            metadata: metadata,
            commentRanks: ranks
        )
        return (output.paths, output.duplicateHashGroups)
    }

    static func sorted(
        _ paths: [String],
        options: Options,
        metadataCache: MetadataCacheService? = nil,
        commentRanks: [String: Int]? = nil
    ) -> [String] {
        sortedWithDuplicateContext(
            paths,
            options: options,
            metadataCache: metadataCache,
            commentRanks: commentRanks
        ).paths
    }

    private static func resolvedCommentRanks(
        paths: [String],
        options: Options,
        commentRanks: [String: Int]?
    ) -> [String: Int] {
        guard options.mode == .comments else { return [:] }
        if let commentRanks {
            return commentRanks
        }
        var ranks: [String: Int] = [:]
        ranks.reserveCapacity(paths.count)
        for path in paths {
            ranks[path] = ImageListCommentStatusCache.shared.sortRank(for: path)
        }
        return ranks
    }
}