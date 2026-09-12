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
        if let cached = cache[path], cached.size > 0 {
            return cached.size
        }
        return entry(for: path)?.size ?? readSize(for: path) ?? 0
    }

    func pixelSize(path: String) -> (width: Int, height: Int)? {
        if let cached = cache[path], cached.pixelWidth > 0, cached.pixelHeight > 0 {
            return (cached.pixelWidth, cached.pixelHeight)
        }
        guard let dims = loadPixelSize(path: path) else { return nil }
        storePixelSize(path: path, width: dims.width, height: dims.height)
        return dims
    }

    /// Store original dimensions captured while generating a thumbnail
    /// (Python `cache_thumbnail_sync` → `_cache_metadata_from_loader`).
    func storePixelSize(path: String, width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        if var existing = cache[path] {
            if existing.pixelWidth == width, existing.pixelHeight == height { return }
            existing.pixelWidth = width
            existing.pixelHeight = height
            cache[path] = existing
            dirty = true
            return
        }
        cache[path] = Entry(
            mtime: readMtime(for: path) ?? 0,
            size: readSize(for: path) ?? 0,
            pixelWidth: width,
            pixelHeight: height,
            exifTimestamp: nil
        )
        dirty = true
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
        let props = loadImageIOProps(path: path)
        let entry = Entry(
            mtime: mtime,
            size: size,
            pixelWidth: props?.width ?? 0,
            pixelHeight: props?.height ?? 0,
            exifTimestamp: props?.exifTimestamp
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
        guard let props = loadImageIOProps(path: path), props.width > 0, props.height > 0 else {
            return nil
        }
        return (props.width, props.height)
    }

    private func loadImageIOProps(path: String) -> (width: Int, height: Int, exifTimestamp: Int?)? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(
            URL(fileURLWithPath: path) as CFURL,
            sourceOptions as CFDictionary
        ) else {
            return nil
        }
        let propertyOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let props = CGImageSourceCopyPropertiesAtIndex(
            source, 0, propertyOptions as CFDictionary
        ) as? [CFString: Any] else {
            return nil
        }
        let rawWidth = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let rawHeight = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let width: Int
        let height: Int
        if (5...8).contains(orientation) {
            width = rawHeight
            height = rawWidth
        } else {
            width = rawWidth
            height = rawHeight
        }
        return (width, height, exifTimestamp(from: props))
    }

    private func exifTimestamp(from props: [CFString: Any]) -> Int? {
        guard let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] else {
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
