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
    }

    static func scanAndSort(_ snapshot: Snapshot) -> [String] {
        let scanned = DirectoryScanner.scanDirectory(
            at: snapshot.path,
            extensions: snapshot.extensions,
            filterPattern: snapshot.filterPattern
        )
        return DirectoryBackgroundSorting.sorted(scanned, snapshot: snapshot)
    }
}

/// Sort paths without `MetadataCacheService` (background-safe file I/O).
private enum DirectoryBackgroundSorting {
    static func sorted(_ paths: [String], snapshot: DirectoryLoadBackgroundWork.Snapshot) -> [String] {
        let mode = SortMode(rawValue: snapshot.sortModeRaw) ?? .date
        let options = Options(mode: mode, reversed: snapshot.sortReversed, useExifDate: snapshot.useExifDate)
        switch options.mode {
        case .random:
            return paths.shuffled()
        case .duplicates:
            let dupes = DuplicateHashService.duplicateSortedPaths(paths)
            return sortDescending(mode: .duplicates, reversed: options.reversed)
                ? dupes.reversed() : dupes
        case .custom:
            guard let directory = commonDirectory(for: paths) else { return paths }
            return PrsortIO.applyCustomOrder(paths: paths, directory: directory)
        case .size:
            return sortBySize(paths, reversed: options.reversed)
        case .comments:
            return sortByComments(paths, reversed: options.reversed)
        default:
            let descending = sortDescending(mode: options.mode, reversed: options.reversed)
            let keyed = paths.map {
                ($0, sortKey(for: $0, mode: options.mode, useExifDate: options.useExifDate))
            }
            return keyed.sorted { lhs, rhs in
                if let ordered = comparePrimary(lhs.1, rhs.1, descending: descending) {
                    return ordered
                }
                return fileNameComesBefore(lhs.0, rhs.0)
            }.map(\.0)
        }
    }

    private struct Options {
        var mode: SortMode
        var reversed: Bool
        var useExifDate: Bool
    }

    private static func sortDescending(mode: SortMode, reversed: Bool) -> Bool {
        switch mode {
        case .name, .ext, .dimensions, .permissions, .duplicates:
            return reversed
        case .comments:
            return !reversed
        case .date, .size, .filesize, .exifDate, .exifYear:
            return !reversed
        default:
            return reversed
        }
    }

    private static func sortByComments(_ paths: [String], reversed: Bool) -> [String] {
        let descending = sortDescending(mode: .comments, reversed: reversed)
        let keyed = paths.map { ($0, 0) }
        return keyed.sorted { lhs, rhs in
            if lhs.1 != rhs.1 {
                return descending ? lhs.1 > rhs.1 : lhs.1 < rhs.1
            }
            return fileNameComesBefore(lhs.0, rhs.0)
        }.map(\.0)
    }

    private static func sortBySize(_ paths: [String], reversed: Bool) -> [String] {
        let descending = sortDescending(mode: .size, reversed: reversed)
        let keyed = paths.map { path in
            (path, sizeSortTuple(for: path, reversed: reversed))
        }
        return keyed.sorted { lhs, rhs in
            if lhs.1.area != rhs.1.area {
                return descending ? lhs.1.area > rhs.1.area : lhs.1.area < rhs.1.area
            }
            if lhs.1.widthKey != rhs.1.widthKey {
                return descending ? lhs.1.widthKey > rhs.1.widthKey : lhs.1.widthKey < rhs.1.widthKey
            }
            return fileNameComesBefore(lhs.0, rhs.0)
        }.map(\.0)
    }

    private struct SizeSortTuple {
        var area: Int64
        var widthKey: Int
    }

    private static func sizeSortTuple(for path: String, reversed: Bool) -> SizeSortTuple {
        let dims = imagePixelSize(path: path)
        let area = dims.map { Int64($0.width * $0.height) } ?? 0
        let width = dims?.width ?? 0
        let widthKey = reversed ? -width : width
        return SizeSortTuple(area: area, widthKey: widthKey)
    }

    private enum SortKey {
        case string(String)
        case number(Int)
        case size(Int64)
    }

    private static func comparePrimary(_ lhs: SortKey, _ rhs: SortKey, descending: Bool) -> Bool? {
        switch (lhs, rhs) {
        case let (.string(a), .string(b)):
            guard a != b else { return nil }
            return descending ? a > b : a < b
        case let (.number(a), .number(b)):
            guard a != b else { return nil }
            return descending ? a > b : a < b
        case let (.size(a), .size(b)):
            guard a != b else { return nil }
            return descending ? a > b : a < b
        default:
            return nil
        }
    }

    private static func commonDirectory(for paths: [String]) -> String? {
        guard let first = paths.first else { return nil }
        return URL(fileURLWithPath: first).deletingLastPathComponent().path
    }

    private static func sortKey(for path: String, mode: SortMode, useExifDate: Bool) -> SortKey {
        switch mode {
        case .name:
            return .string((path as NSString).lastPathComponent.lowercased())
        case .ext:
            return .string((path as NSString).pathExtension.lowercased())
        case .filesize, .size:
            let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            return .size(bytes)
        case .date:
            return .number(fileTimestamp(path: path, preferExif: false))
        case .exifDate, .exifYear:
            return .number(fileTimestamp(path: path, preferExif: useExifDate))
        case .dimensions:
            if let dims = imagePixelSize(path: path) {
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

    private static func fileTimestamp(path: String, preferExif: Bool) -> Int {
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

    private static func fileNameComesBefore(_ lhs: String, _ rhs: String) -> Bool {
        (lhs as NSString).lastPathComponent.lowercased() < (rhs as NSString).lastPathComponent.lowercased()
    }
}
