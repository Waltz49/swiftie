import Foundation
import ImageIO

/// Persists file metadata for sorting. Port of `cache/image_cache.py` metadata cache (simplified).
@MainActor
final class MetadataCacheService {
    struct Entry: Codable {
        var mtime: TimeInterval
        var size: Int64
        var pixelWidth: Int
        var pixelHeight: Int
        var exifTimestamp: Int?
    }

    private var cache: [String: Entry] = [:]
    private let cacheFile: URL
    private var dirty = false
    private let maxEntries = 12_000

    var entryCount: Int { cache.count }

    init(paths: ProfilePaths) {
        cacheFile = paths.metadataCacheDirectory.appendingPathComponent("metadata_cache.json")
        load()
    }

    func fileTimestamp(path: String, preferExif: Bool) -> Int {
        let entry = entry(for: path)
        if preferExif, let exif = entry?.exifTimestamp {
            return exif
        }
        if let entry {
            return Int(entry.mtime)
        }
        return Int(readMtime(for: path) ?? 0)
    }

    func fileSize(path: String) -> Int64 {
        entry(for: path)?.size ?? readSize(for: path) ?? 0
    }

    func pixelSize(path: String) -> (width: Int, height: Int)? {
        if let entry = entry(for: path), entry.pixelWidth > 0, entry.pixelHeight > 0 {
            return (entry.pixelWidth, entry.pixelHeight)
        }
        return loadPixelSize(path: path)
    }

    func invalidate(path: String) {
        cache.removeValue(forKey: path)
        dirty = true
    }

    /// Cached entry without disk validation (pre-rename capture; Python `get_metadata_sync(old_path)`).
    func rawEntry(for path: String) -> Entry? {
        cache[path]
    }

    /// Re-key a captured entry under a renamed path. mtime/size are re-read from disk; pixel
    /// dimensions and EXIF timestamp are kept so headers are not decoded again
    /// (Python `ImageMetadata._replace(filename=..., modified_time=..., file_size=...)`).
    func storeMigratedEntry(_ entry: Entry, for newPath: String) {
        guard let mtime = readMtime(for: newPath), let size = readSize(for: newPath) else { return }
        cache[newPath] = Entry(
            mtime: mtime,
            size: size,
            pixelWidth: entry.pixelWidth,
            pixelHeight: entry.pixelHeight,
            exifTimestamp: entry.exifTimestamp
        )
        dirty = true
    }

    /// Update only the recorded mtime after `os.utime` (Python `_replace(modified_time=...)`).
    func updateModificationTime(path: String) {
        guard let existing = cache[path], let mtime = readMtime(for: path) else { return }
        cache[path] = Entry(
            mtime: mtime,
            size: existing.size,
            pixelWidth: existing.pixelWidth,
            pixelHeight: existing.pixelHeight,
            exifTimestamp: existing.exifTimestamp
        )
        dirty = true
    }

    /// Returns true when file mtime or size differs from the last recorded snapshot.
    func fileChangedOnDisk(path: String) -> Bool {
        guard let diskMtime = readMtime(for: path),
              let diskSize = readSize(for: path) else { return false }
        guard let cached = cache[path] else {
            recordDiskSnapshot(path: path, mtime: diskMtime, size: diskSize)
            return false
        }
        return abs(cached.mtime - diskMtime) >= 0.001 || cached.size != diskSize
    }

    func recordDiskSnapshot(path: String) {
        guard let mtime = readMtime(for: path),
              let size = readSize(for: path) else { return }
        recordDiskSnapshot(path: path, mtime: mtime, size: size)
    }

    private func recordDiskSnapshot(path: String, mtime: TimeInterval, size: Int64) {
        if let existing = cache[path] {
            cache[path] = Entry(
                mtime: mtime,
                size: size,
                pixelWidth: existing.pixelWidth,
                pixelHeight: existing.pixelHeight,
                exifTimestamp: existing.exifTimestamp
            )
        } else {
            cache[path] = Entry(
                mtime: mtime,
                size: size,
                pixelWidth: 0,
                pixelHeight: 0,
                exifTimestamp: nil
            )
        }
        dirty = true
    }

    func saveIfNeeded() {
        guard dirty else { return }
        dirty = false
        if cache.count > maxEntries {
            let trimmed = Array(cache.sorted { $0.key < $1.key }.suffix(maxEntries))
            cache = Dictionary(uniqueKeysWithValues: trimmed)
        }
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheFile, options: .atomic)
    }

    private func entry(for path: String) -> Entry? {
        guard let mtime = readMtime(for: path) else { return nil }
        if let cached = cache[path], abs(cached.mtime - mtime) < 0.001 {
            return cached
        }
        let size = readSize(for: path) ?? 0
        let pixels = loadPixelSize(path: path) ?? (0, 0)
        let exif = loadExifTimestamp(path: path)
        let entry = Entry(
            mtime: mtime,
            size: size,
            pixelWidth: pixels.width,
            pixelHeight: pixels.height,
            exifTimestamp: exif
        )
        cache[path] = entry
        dirty = true
        return entry
    }

    private func load() {
        guard let data = try? Data(contentsOf: cacheFile),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return
        }
        cache = decoded
    }

    private func readMtime(for path: String) -> TimeInterval? {
        guard let date = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date else {
            return nil
        }
        return date.timeIntervalSince1970
    }

    private func readSize(for path: String) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
    }

    private func loadPixelSize(path: String) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            return nil
        }
        return (width, height)
    }

    private func loadExifTimestamp(path: String) -> Int? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] else {
            return nil
        }
        let keys = [
            kCGImagePropertyExifDateTimeOriginal,
            kCGImagePropertyExifDateTimeDigitized,
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        for key in keys {
            if let raw = exif[key] as? String,
               let date = formatter.date(from: raw) {
                return Int(date.timeIntervalSince1970)
            }
        }
        return nil
    }
}
