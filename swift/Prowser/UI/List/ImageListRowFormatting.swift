import Foundation

struct ImageListRowData: Equatable, Sendable {
    var permissions: String
    var dateText: String
    var sizeText: String
    var dimensionsText: String
    var nameText: String
    var extensionText: String
}

/// Row text/formatting for the list view. Port of `view_manager.update_list_view` field formatting.
@MainActor
enum ImageListRowFormatting {
    static func buildRowDataMap(
        paths: [String],
        metadataCache: MetadataCacheService?
    ) -> [String: ImageListRowData] {
        let nameDisplay = nameColumnDisplay(for: paths)
        var map: [String: ImageListRowData] = [:]
        map.reserveCapacity(paths.count)
        for path in paths {
            map[path] = rowData(for: path, nameDisplay: nameDisplay, metadataCache: metadataCache)
        }
        return map
    }

    static let singleDirectoryBannerPrefix = "Single Directory: "
    static let multipleDirectoriesBannerPrefix = "Multiple Directories: "

    struct DirectoryBannerContent: Equatable {
        enum Kind: Equatable {
            case singleDirectory(directory: String)
            case multipleDirectories(commonRoot: String)
            case plain(String)
        }

        let kind: Kind
    }

    static func listHeaderDirectoryBannerContent(for paths: [String]) -> DirectoryBannerContent? {
        guard !paths.isEmpty else { return nil }
        var directories = Set<String>()
        for path in paths {
            let dir = parentDirectoryPath(path)
            directories.insert(dir)
        }
        if directories.count == 1, let only = directories.first {
            return DirectoryBannerContent(
                kind: .singleDirectory(
                    directory: InformationFormatting.normalizePathForDisplay(only)
                )
            )
        }
        if let root = minimumCommonParentDirectory(for: paths) {
            let displayRoot = InformationFormatting.normalizePathForDisplay(root)
            return DirectoryBannerContent(kind: .multipleDirectories(commonRoot: displayRoot))
        }
        return DirectoryBannerContent(kind: .plain("Multiple Directories"))
    }

    static func formatListFileSize(bytes: Int64) -> String {
        let sizeKB = Int((Double(bytes) / 1024.0).rounded())
        return "\(sizeKB) KB"
    }

    static func formatPermissions(at path: String) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mode = attrs[.posixPermissions] as? Int else {
            return "----------"
        }
        return posixPermissionString(mode)
    }

    static func formatDate(path: String, metadataCache: MetadataCacheService?) -> String {
        if let cache = metadataCache {
            let ts = cache.fileTimestamp(path: path, preferExif: false)
            if ts > 0 {
                return InformationFormatting.formatFileDate(Date(timeIntervalSince1970: TimeInterval(ts)))
            }
        }
        if let mtime = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date {
            return InformationFormatting.formatFileDate(mtime)
        }
        return "0000-00-00 00:00:00"
    }

    static func formatDimensions(path: String, metadataCache: MetadataCacheService?) -> String {
        if let dims = metadataCache?.pixelSize(path: path), dims.width > 0, dims.height > 0 {
            return "\(dims.width)x\(dims.height)"
        }
        return "0x0"
    }

    private enum NameColumnDisplay: Equatable {
        case basename
        case relativeToCommonRoot(String)
        case fullPath
    }

    private static func rowData(
        for path: String,
        nameDisplay: NameColumnDisplay,
        metadataCache: MetadataCacheService?
    ) -> ImageListRowData {
        let bytes = metadataCache?.fileSize(path: path)
            ?? (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
            ?? 0
        let name: String
        switch nameDisplay {
        case .basename:
            name = (path as NSString).lastPathComponent
        case .relativeToCommonRoot(let root):
            name = pathRelativeToDirectory(path, directory: root)
        case .fullPath:
            name = InformationFormatting.normalizePathForDisplay(path)
        }
        return ImageListRowData(
            permissions: formatPermissions(at: path),
            dateText: formatDate(path: path, metadataCache: metadataCache),
            sizeText: formatListFileSize(bytes: bytes),
            dimensionsText: formatDimensions(path: path, metadataCache: metadataCache),
            nameText: name,
            extensionText: (path as NSString).pathExtension
        )
    }

    static func nameOmittingExtension(_ name: String, path: String) -> String {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty else { return name }
        let suffix = "." + ext
        if name.count > suffix.count, name.suffix(suffix.count).caseInsensitiveCompare(suffix) == .orderedSame {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    private static func nameColumnDisplay(for paths: [String]) -> NameColumnDisplay {
        guard !paths.isEmpty else { return .basename }
        if !pathsSpanMultipleDirectories(paths) { return .basename }
        if let root = minimumCommonParentDirectory(for: paths) {
            return .relativeToCommonRoot(root)
        }
        return .fullPath
    }

    private static func pathsSpanMultipleDirectories(_ paths: [String]) -> Bool {
        guard let first = paths.first else { return false }
        let firstDir = parentDirectoryPath(first)
        for path in paths.dropFirst() {
            if parentDirectoryPath(path) != firstDir { return true }
        }
        return false
    }

    /// Longest shared parent directory when files span multiple folders; nil if only `/` is shared.
    static func minimumCommonParentDirectory(for paths: [String]) -> String? {
        guard paths.count >= 2, pathsSpanMultipleDirectories(paths) else { return nil }
        var common = parentDirectoryPath(paths[0])
        for path in paths.dropFirst() {
            common = posixCommonPath(common, parentDirectoryPath(path))
        }
        if common == "/" || common.isEmpty {
            return nil
        }
        return common
    }

    private static func parentDirectoryPath(_ path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
    }

    private static func posixCommonPath(_ path1: String, _ path2: String) -> String {
        let standardized1 = (path1 as NSString).standardizingPath
        let standardized2 = (path2 as NSString).standardizingPath
        let components1 = (standardized1 as NSString).pathComponents
        let components2 = (standardized2 as NSString).pathComponents
        var shared: [String] = []
        for (left, right) in zip(components1, components2) where left == right {
            shared.append(left)
        }
        if shared.isEmpty { return "/" }
        return NSString.path(withComponents: shared)
    }

    private static func pathRelativeToDirectory(_ filePath: String, directory: String) -> String {
        let file = URL(fileURLWithPath: filePath).standardizedFileURL.path
        var dir = URL(fileURLWithPath: directory).standardizedFileURL.path
        if !dir.hasSuffix("/") { dir += "/" }
        guard file.hasPrefix(dir) else {
            return InformationFormatting.normalizePathForDisplay(filePath)
        }
        return String(file.dropFirst(dir.count))
    }

    private static func posixPermissionString(_ mode: Int) -> String {
        let triplets = ["---", "--x", "-w-", "-wx", "r--", "r-x", "rw-", "rwx"]
        var result = ""
        for shift in [6, 3, 0] {
            let value = (mode >> shift) & 7
            result += triplets[value]
        }
        return result
    }
}
