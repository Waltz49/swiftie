import Foundation
import ImageIO

/// Shared path sorting for main-thread and background directory work.
enum ImagePathSortingKernel {
    struct Options: Sendable {
        var mode: SortMode
        var reversed: Bool
        var useExifDate: Bool
    }

    struct SortOutput: Sendable {
        var paths: [String]
        var duplicateHashGroups: DuplicateHashService.HashGroups?
    }

    /// Merge two lists that are each sorted in the same mode (incremental disk refresh).
    static func mergeSorted(
        existing: [String],
        newPaths: [String],
        options: Options,
        metadata: MetadataCacheSnapshot?,
        commentRanks: [String: Int] = [:]
    ) -> [String] {
        guard !newPaths.isEmpty else { return existing }
        guard !existing.isEmpty else {
            return sort(newPaths, options: options, metadata: metadata, commentRanks: commentRanks).paths
        }
        let sortedNew = sort(newPaths, options: options, metadata: metadata, commentRanks: commentRanks).paths
        return mergeSortedLists(existing, sortedNew, options: options, metadata: metadata, commentRanks: commentRanks)
    }

    static func sort(
        _ paths: [String],
        options: Options,
        metadata: MetadataCacheSnapshot?,
        commentRanks: [String: Int] = [:]
    ) -> SortOutput {
        let duplicateDescending = sortDescending(mode: .duplicates, reversed: options.reversed)
        switch options.mode {
        case .random:
            return SortOutput(paths: paths.shuffled(), duplicateHashGroups: nil)
        case .duplicates:
            let result = DuplicateHashService.duplicateSortResult(
                filePaths: paths,
                reversed: duplicateDescending
            )
            return SortOutput(paths: result.sortedPaths, duplicateHashGroups: result.hashGroups)
        case .custom:
            guard let directory = commonDirectory(for: paths) else {
                return SortOutput(paths: paths, duplicateHashGroups: nil)
            }
            return SortOutput(paths: PrsortIO.applyCustomOrder(paths: paths, directory: directory), duplicateHashGroups: nil)
        case .size:
            return SortOutput(
                paths: sortBySize(paths, reversed: options.reversed, metadata: metadata),
                duplicateHashGroups: nil
            )
        case .comments:
            return SortOutput(
                paths: sortByComments(paths, reversed: options.reversed, ranks: commentRanks),
                duplicateHashGroups: nil
            )
        default:
            let descending = sortDescending(mode: options.mode, reversed: options.reversed)
            let keyed = paths.map {
                ($0, sortKey(for: $0, mode: options.mode, useExifDate: options.useExifDate, metadata: metadata))
            }
            let sorted = keyed.sorted { lhs, rhs in
                if let ordered = comparePrimary(lhs.1, rhs.1, descending: descending) {
                    return ordered
                }
                return fileNameComesBefore(lhs.0, rhs.0)
            }.map(\.0)
            return SortOutput(paths: sorted, duplicateHashGroups: nil)
        }
    }

    /// Sort modes where a sorted merge of additions is valid.
    static func supportsIncrementalMerge(_ mode: SortMode) -> Bool {
        switch mode {
        case .random, .custom, .duplicates:
            return false
        default:
            return true
        }
    }

    private static func mergeSortedLists(
        _ lhs: [String],
        _ rhs: [String],
        options: Options,
        metadata: MetadataCacheSnapshot?,
        commentRanks: [String: Int]
    ) -> [String] {
        let descending = sortDescending(mode: options.mode, reversed: options.reversed)
        var result: [String] = []
        result.reserveCapacity(lhs.count + rhs.count)
        var i = 0
        var j = 0
        while i < lhs.count, j < rhs.count {
            let leftPath = lhs[i]
            let rightPath = rhs[j]
            if pathsOrdered(leftPath, before: rightPath, mode: options.mode, useExifDate: options.useExifDate, descending: descending, metadata: metadata, commentRanks: commentRanks) {
                result.append(leftPath)
                i += 1
            } else {
                result.append(rightPath)
                j += 1
            }
        }
        if i < lhs.count {
            result.append(contentsOf: lhs[i...])
        }
        if j < rhs.count {
            result.append(contentsOf: rhs[j...])
        }
        return result
    }

    private static func pathsOrdered(
        _ lhs: String,
        before rhs: String,
        mode: SortMode,
        useExifDate: Bool,
        descending: Bool,
        metadata: MetadataCacheSnapshot?,
        commentRanks: [String: Int]
    ) -> Bool {
        if mode == .comments {
            let lRank = commentRanks[lhs] ?? backgroundCommentSortRank(for: lhs)
            let rRank = commentRanks[rhs] ?? backgroundCommentSortRank(for: rhs)
            if lRank != rRank {
                return descending ? lRank > rRank : lRank < rRank
            }
            return fileNameComesBefore(lhs, rhs)
        }
        let lKey = sortKey(for: lhs, mode: mode, useExifDate: useExifDate, metadata: metadata)
        let rKey = sortKey(for: rhs, mode: mode, useExifDate: useExifDate, metadata: metadata)
        if let ordered = comparePrimary(lKey, rKey, descending: descending) {
            return ordered
        }
        return fileNameComesBefore(lhs, rhs)
    }

    static func backgroundCommentSortRank(for path: String) -> Int {
        ImageListCommentService.classify(path: path).indicator.sortRank
    }

    static func backgroundCommentRanks(for paths: [String]) -> [String: Int] {
        var ranks: [String: Int] = [:]
        ranks.reserveCapacity(paths.count)
        for path in paths {
            ranks[path] = backgroundCommentSortRank(for: path)
        }
        return ranks
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

    private static func sortByComments(
        _ paths: [String],
        reversed: Bool,
        ranks: [String: Int]
    ) -> [String] {
        let descending = sortDescending(mode: .comments, reversed: reversed)
        let keyed = paths.map { path in
            (path, ranks[path] ?? backgroundCommentSortRank(for: path))
        }
        return keyed.sorted { lhs, rhs in
            if lhs.1 != rhs.1 {
                return descending ? lhs.1 > rhs.1 : lhs.1 < rhs.1
            }
            return fileNameComesBefore(lhs.0, rhs.0)
        }.map(\.0)
    }

    private static func sortBySize(
        _ paths: [String],
        reversed: Bool,
        metadata: MetadataCacheSnapshot?
    ) -> [String] {
        let descending = sortDescending(mode: .size, reversed: reversed)
        let keyed = paths.map { path in
            (path, sizeSortTuple(for: path, reversed: reversed, metadata: metadata))
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

    private static func sizeSortTuple(
        for path: String,
        reversed: Bool,
        metadata: MetadataCacheSnapshot?
    ) -> SizeSortTuple {
        let dims = metadata?.pixelSize(path: path) ?? imagePixelSize(path: path)
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

    private static func sortKey(
        for path: String,
        mode: SortMode,
        useExifDate: Bool,
        metadata: MetadataCacheSnapshot?
    ) -> SortKey {
        switch mode {
        case .name:
            return .string((path as NSString).lastPathComponent.lowercased())
        case .ext:
            return .string((path as NSString).pathExtension.lowercased())
        case .filesize:
            if let bytes = metadata?.fileSize(path: path) {
                return .size(bytes)
            }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            return .size(bytes)
        case .size:
            if let dims = metadata?.pixelSize(path: path) ?? imagePixelSize(path: path) {
                return .size(Int64(dims.width * dims.height))
            }
            return .size(0)
        case .date:
            return .number(fileTimestamp(path: path, preferExif: false, metadata: metadata))
        case .exifDate, .exifYear:
            return .number(fileTimestamp(path: path, preferExif: useExifDate, metadata: metadata))
        case .dimensions:
            if let dims = metadata?.pixelSize(path: path) ?? imagePixelSize(path: path) {
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
        metadata: MetadataCacheSnapshot?
    ) -> Int {
        if let cached = metadata?.fileTimestamp(path: path, preferExif: preferExif) {
            return cached
        }
        if preferExif, let exifDate = exifCaptureDate(path: path) {
            return Int(exifDate.timeIntervalSince1970)
        }
        if let mtime = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date {
            return Int(mtime.timeIntervalSince1970)
        }
        return 0
    }

    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    private static func exifCaptureDate(path: String) -> Date? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(
            URL(fileURLWithPath: path) as CFURL,
            sourceOptions as CFDictionary
        ),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions as CFDictionary) as? [CFString: Any]
        else {
            return nil
        }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let dateString = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            return exifDateFormatter.date(from: dateString)
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let dateString = tiff[kCGImagePropertyTIFFDateTime] as? String {
            return exifDateFormatter.date(from: dateString)
        }
        return nil
    }

    private static func imagePixelSize(path: String) -> (width: Int, height: Int)? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(
            URL(fileURLWithPath: path) as CFURL,
            sourceOptions as CFDictionary
        ),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions as CFDictionary) as? [CFString: Any],
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
