import Foundation
import ImageIO

/// Off–main-thread directory scan + sort for `DirectoryLoadCoordinator`.
enum DirectoryLoadBackgroundWork {
    struct Snapshot: Sendable {
        let path: String
        let extensions: [String]
        let filterPattern: String
        let sortModeRaw: String
        let sortReversed: Bool
        let useExifDate: Bool
        let metadataCacheFilePath: String
    }

    struct SortOutput: Sendable {
        var paths: [String]
        var duplicateHashGroups: DuplicateHashService.HashGroups?
    }

    static func scanAndSort(_ snapshot: Snapshot) -> SortOutput {
        let scanStart = CFAbsoluteTimeGetCurrent()
        let scanned = DirectoryScanner.scanDirectory(
            at: snapshot.path,
            extensions: snapshot.extensions,
            filterPattern: snapshot.filterPattern
        )
        let scanMs = (CFAbsoluteTimeGetCurrent() - scanStart) * 1000
        DirectoryLoadPerfDiagnostics.recordScan(durationMs: scanMs, pathCount: scanned.count)
        return sort(scanned, snapshot: snapshot)
    }

    static func sort(_ paths: [String], snapshot: Snapshot) -> SortOutput {
        let sortStart = CFAbsoluteTimeGetCurrent()
        let metadata = MetadataCacheSnapshot.load(cacheFilePath: snapshot.metadataCacheFilePath)
        let mode = SortMode(rawValue: snapshot.sortModeRaw) ?? .date
        let options = ImagePathSortingKernel.Options(
            mode: mode,
            reversed: snapshot.sortReversed,
            useExifDate: snapshot.useExifDate
        )
        let commentRanks = mode == .comments ? ImagePathSortingKernel.backgroundCommentRanks(for: paths) : [:]
        let sorted = ImagePathSortingKernel.sort(
            paths,
            options: options,
            metadata: metadata,
            commentRanks: commentRanks
        )
        let sortMs = (CFAbsoluteTimeGetCurrent() - sortStart) * 1000
        DirectoryLoadPerfDiagnostics.recordSort(
            durationMs: sortMs,
            pathCount: sorted.paths.count,
            sortMode: snapshot.sortModeRaw
        )
        return SortOutput(paths: sorted.paths, duplicateHashGroups: sorted.duplicateHashGroups)
    }
}