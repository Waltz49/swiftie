import Foundation

/// Read-only view of persisted metadata for background directory sorting.
struct MetadataCacheSnapshot: Sendable {
    struct Entry: Codable, Sendable {
        var mtime: TimeInterval
        var size: Int64
        var pixelWidth: Int
        var pixelHeight: Int
        var exifTimestamp: Int?
    }

    static func load(cacheFilePath: String) -> MetadataCacheSnapshot {
        let url = URL(fileURLWithPath: cacheFilePath)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return MetadataCacheSnapshot(entries: [:])
        }
        return MetadataCacheSnapshot(entries: decoded)
    }

    static func forSorting(diskCacheFilePath: String, liveMemory: MetadataCacheSnapshot?) -> MetadataCacheSnapshot {
        var merged = load(cacheFilePath: diskCacheFilePath).entries
        if let liveMemory {
            for (path, entry) in liveMemory.entries {
                merged[path] = entry
            }
        }
        return MetadataCacheSnapshot(entries: merged)
    }

    /// In-memory entries (e.g. from ``MetadataCacheService/sortingSnapshot()``).
    var entries: [String: Entry] {
        entriesBacking
    }

    private let entriesBacking: [String: Entry]

    init(entries: [String: Entry]) {
        entriesBacking = entries
    }

    func fileSize(path: String) -> Int64? {
        guard let entry = validatedEntry(for: path) else { return nil }
        return entry.size > 0 ? entry.size : nil
    }

    func pixelSize(path: String) -> (width: Int, height: Int)? {
        guard let entry = validatedEntry(for: path),
              entry.pixelWidth > 0,
              entry.pixelHeight > 0 else { return nil }
        return (entry.pixelWidth, entry.pixelHeight)
    }

    func fileTimestamp(path: String, preferExif: Bool) -> Int? {
        guard let entry = validatedEntry(for: path) else { return nil }
        if preferExif {
            guard let exif = entry.exifTimestamp else { return nil }
            return exif
        }
        return Int(entry.mtime)
    }

    private func validatedEntry(for path: String) -> Entry? {
        guard let cached = entriesBacking[path] else { return nil }
        guard let diskMtime = MetadataCacheService.readDiskSnapshot(path: path)?.mtime else {
            return nil
        }
        guard abs(cached.mtime - diskMtime) < 0.001 else { return nil }
        return cached
    }
}