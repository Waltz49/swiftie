import Foundation
import ImageIO

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

    static func sorted(
        _ paths: [String],
        options: Options,
        metadataCache: MetadataCacheService? = nil
    ) -> [String] {
        switch options.mode {
        case .random:
            return paths.shuffled()
        case .duplicates:
            let dupes = DuplicateHashService.duplicateSortedPaths(paths)
            return options.reversed ? dupes.reversed() : dupes
        case .custom:
            guard let directory = commonDirectory(for: paths) else {
                return options.reversed ? paths.reversed() : paths
            }
            let ordered = PrsortIO.applyCustomOrder(paths: paths, directory: directory)
            return options.reversed ? ordered.reversed() : ordered
        default:
            let keyed = paths.map {
                ( $0, sortKey(for: $0, mode: options.mode, useExifDate: options.useExifDate, metadataCache: metadataCache) )
            }
            let sortedKeys = keyed.sorted { lhs, rhs in
                switch (lhs.1, rhs.1) {
                case let (.string(a), .string(b)):
                    return options.reversed ? a > b : a < b
                case let (.number(a), .number(b)):
                    return options.reversed ? a > b : a < b
                case let (.size(a), .size(b)):
                    return options.reversed ? a > b : a < b
                default:
                    return options.reversed ? lhs.0 > rhs.0 : lhs.0 < rhs.0
                }
            }
            return sortedKeys.map(\.0)
        }
    }

    private enum SortKey {
        case string(String)
        case number(Int)
        case size(Int64)
    }

    private static func commonDirectory(for paths: [String]) -> String? {
        guard let first = paths.first else { return nil }
        return URL(fileURLWithPath: first).deletingLastPathComponent().path
    }

    private static func sortKey(
        for path: String,
        mode: SortMode,
        useExifDate: Bool,
        metadataCache: MetadataCacheService?
    ) -> SortKey {
        switch mode {
        case .name:
            return .string((path as NSString).lastPathComponent.lowercased())
        case .filesize, .size:
            if let cache = metadataCache {
                return .size(cache.fileSize(path: path))
            }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            return .size(bytes)
        case .date:
            return .number(fileTimestamp(path: path, preferExif: false, metadataCache: metadataCache))
        case .exifDate, .exifYear:
            return .number(fileTimestamp(path: path, preferExif: useExifDate, metadataCache: metadataCache))
        case .dimensions:
            if let dims = metadataCache?.pixelSize(path: path) ?? imagePixelSize(path: path) {
                return .size(Int64(dims.width * dims.height))
            }
            return .size(0)
        case .permissions:
            let perms = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? 0
            return .number(perms)
        default:
            return .string(path.lowercased())
        }
    }

    private static func fileTimestamp(
        path: String,
        preferExif: Bool,
        metadataCache: MetadataCacheService?
    ) -> Int {
        if let cache = metadataCache {
            return cache.fileTimestamp(path: path, preferExif: preferExif)
        }
        if preferExif, let exifDate = exifCaptureDate(path: path) {
            return Int(exifDate.timeIntervalSince1970)
        }
        if let mtime = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date {
            return Int(mtime.timeIntervalSince1970)
        }
        return 0
    }

    private static func exifCaptureDate(path: String) -> Date? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let dateString = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            return parseExifDate(dateString)
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let dateString = tiff[kCGImagePropertyTIFFDateTime] as? String {
            return parseExifDate(dateString)
        }
        return nil
    }

    private static func parseExifDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: value)
    }

    private static func imagePixelSize(path: String) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }
}
