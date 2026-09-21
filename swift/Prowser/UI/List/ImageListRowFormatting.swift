import Foundation

struct ImageListRowData: Equatable, Sendable {
    var permissions: String
    var dateText: String
    var sizeText: String
    var dimensionsText: String
    var nameText: String
}

/// Row text/formatting for the list view. Port of `view_manager.update_list_view` field formatting.
@MainActor
enum ImageListRowFormatting {
    static func buildRowDataMap(
        paths: [String],
        metadataCache: MetadataCacheService?
    ) -> [String: ImageListRowData] {
        let showFullPath = shouldShowFullPath(for: paths)
        var map: [String: ImageListRowData] = [:]
        map.reserveCapacity(paths.count)
        for path in paths {
            map[path] = rowData(for: path, showFullPath: showFullPath, metadataCache: metadataCache)
        }
        return map
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

    private static func rowData(
        for path: String,
        showFullPath: Bool,
        metadataCache: MetadataCacheService?
    ) -> ImageListRowData {
        let bytes = metadataCache?.fileSize(path: path)
            ?? (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
            ?? 0
        let name: String
        if showFullPath {
            name = InformationFormatting.normalizePathForDisplay(path)
        } else {
            name = (path as NSString).lastPathComponent
        }
        return ImageListRowData(
            permissions: formatPermissions(at: path),
            dateText: formatDate(path: path, metadataCache: metadataCache),
            sizeText: formatListFileSize(bytes: bytes),
            dimensionsText: formatDimensions(path: path, metadataCache: metadataCache),
            nameText: name
        )
    }

    private static func shouldShowFullPath(for paths: [String]) -> Bool {
        guard let first = paths.first else { return false }
        let firstDir = URL(fileURLWithPath: first).deletingLastPathComponent().path
        for path in paths.dropFirst() {
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
            if dir != firstDir { return true }
        }
        return false
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
