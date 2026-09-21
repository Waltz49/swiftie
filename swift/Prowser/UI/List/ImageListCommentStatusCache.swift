import Foundation

/// In-memory comment indicator cache for the list view (key: filename + mtime hash).
@MainActor
final class ImageListCommentStatusCache {
    static let shared = ImageListCommentStatusCache()

    private static let entryTTL: TimeInterval = 600

    private struct Entry {
        var info: ImageListCommentInfo
        var lastAccess: Date
    }

    private var entries: [UInt64: Entry] = [:]
    /// Path-keyed ranks for list sort (no file I/O). Mirrors displayed Cmt values.
    private var pathRanks: [String: Int] = [:]

    private init() {}

    func info(for path: String) -> ImageListCommentInfo? {
        pruneExpiredEntries()
        return entryInfo(for: path, touch: true)
    }

    func store(path: String, info: ImageListCommentInfo) {
        pathRanks[path] = info.indicator.sortRank
        pruneExpiredEntries()
        guard let key = cacheKey(for: path) else { return }
        entries[key] = Entry(info: info, lastAccess: Date())
    }

    func prime(paths: [String]) -> [String: ImageListCommentInfo] {
        pruneExpiredEntries()
        var map: [String: ImageListCommentInfo] = [:]
        map.reserveCapacity(paths.count)
        for path in paths {
            if let info = entryInfo(for: path, touch: true) {
                map[path] = info
            }
        }
        return map
    }

    func pathsNeedingLoad(_ paths: [String]) -> [String] {
        pruneExpiredEntries()
        return paths.filter { entryInfo(for: $0, touch: false) == nil }
    }

    /// Sort key from already-known column values (no EXIF, no stat). Missing → blank.
    func sortRank(for path: String) -> Int {
        pathRanks[path] ?? 0
    }

    /// Snapshot ranks for the current list. Displayed column values win.
    func snapshotSortRanks(
        for paths: [String],
        displayed: [String: ImageListCommentInfo]
    ) -> [String: Int] {
        var ranks: [String: Int] = [:]
        ranks.reserveCapacity(paths.count)
        for path in paths {
            if let info = displayed[path] {
                let rank = info.indicator.sortRank
                pathRanks[path] = rank
                ranks[path] = rank
            } else {
                ranks[path] = pathRanks[path] ?? 0
            }
        }
        return ranks
    }

    private func entryInfo(for path: String, touch: Bool) -> ImageListCommentInfo? {
        guard let key = cacheKey(for: path), var entry = entries[key] else { return nil }
        if Date().timeIntervalSince(entry.lastAccess) > Self.entryTTL {
            entries.removeValue(forKey: key)
            return nil
        }
        if touch {
            entry.lastAccess = Date()
            entries[key] = entry
        }
        return entry.info
    }

    private func cacheKey(for path: String) -> UInt64? {
        let filename = (path as NSString).lastPathComponent
        guard let mtime = fileModificationTime(path: path) else { return nil }
        return Self.hash(filename: filename, mtime: mtime)
    }

    private func fileModificationTime(path: String) -> TimeInterval? {
        guard let date = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date else {
            return nil
        }
        return date.timeIntervalSince1970
    }

    private static func hash(filename: String, mtime: TimeInterval) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(filename)
        hasher.combine(mtime)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    private func pruneExpiredEntries() {
        let now = Date()
        entries = entries.filter { now.timeIntervalSince($0.value.lastAccess) <= Self.entryTTL }
    }
}
