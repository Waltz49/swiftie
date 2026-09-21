import AppKit
import Foundation

/// Identifies a list-view column. Add new cases here when introducing categories.
enum ImageListColumnID: String, CaseIterable, Codable, Sendable {
    case thumbnail
    case permissions
    case date
    case size
    case dimensions
    case comments
    case name
    case ext

    /// Table column order (thumbnail is always first).
    static let defaultOrder: [ImageListColumnID] = [
        .thumbnail, .name, .ext, .date, .size, .dimensions, .permissions, .comments,
    ]

    /// Right-click column visibility menu (thumbnail is not listed).
    static let columnSelectorMenuOrder: [ImageListColumnID] = [
        .name, .ext, .date, .size, .dimensions, .permissions, .comments,
    ]

    var title: String {
        switch self {
        case .thumbnail: return ""
        case .permissions: return "Perm"
        case .date: return "Date"
        case .size: return "Size"
        case .dimensions: return "Dim"
        case .comments: return "Cmt"
        case .name: return "Name"
        case .ext: return "Ext"
        }
    }

    var menuTitle: String {
        switch self {
        case .thumbnail: return "Thumbnail"
        case .permissions: return "Permissions"
        case .date: return "Date"
        case .size: return "Size"
        case .dimensions: return "Dimensions"
        case .comments: return "Comments"
        case .name: return "Name"
        case .ext: return "Extension"
        }
    }

    /// Sort mode when the user clicks this column header (`nil` = not sortable).
    var sortMode: SortMode? {
        switch self {
        case .thumbnail: return nil
        case .permissions: return .permissions
        case .date: return .date
        case .size: return .filesize
        case .dimensions: return .dimensions
        case .comments: return .comments
        case .name: return .name
        case .ext: return .ext
        }
    }

    var canHide: Bool {
        self != .thumbnail
    }

    var defaultWidth: CGFloat {
        switch self {
        case .thumbnail: return 96
        case .permissions: return 70
        case .date: return Self.dateColumnWidth
        case .size: return 70
        case .dimensions: return 100
        case .comments: return 58
        case .name: return 200
        case .ext: return 56
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .thumbnail: return 56
        case .name: return 80
        case .comments, .ext: return 52
        case .date: return Self.dateColumnWidth
        default: return 48
        }
    }

    /// Full `yyyy-MM-dd HH:mm:ss` plus label insets so list dates are not elided.
    private static let dateColumnWidth: CGFloat = {
        let sample = "0000-00-00 00:00:00"
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let textWidth = ceil((sample as NSString).size(withAttributes: [.font: font]).width)
        return textWidth + 20
    }()

    var textAlignment: NSTextAlignment {
        switch self {
        case .permissions, .size, .dimensions, .comments, .ext:
            return .center
        case .date:
            return .right
        case .name, .thumbnail:
            return .left
        }
    }

    /// Header labels (including sort ▲/▼) are centered in the column; row alignment is separate.
    var headerTextAlignment: NSTextAlignment {
        switch self {
        case .thumbnail: return .left
        default: return .center
        }
    }
}

/// Column order and visibility for the image list (persisted in settings).
@MainActor
final class ImageListColumnLayout {
    private(set) var columnOrder: [ImageListColumnID]
    private(set) var hiddenColumns: Set<ImageListColumnID>

    var visibleColumns: [ImageListColumnID] {
        columnOrder.filter { !hiddenColumns.contains($0) }
    }

    init() {
        columnOrder = ImageListColumnID.defaultOrder
        hiddenColumns = [.comments, .ext]
    }

    func load(from config: AppConfig) {
        let orderRaw = config.string(forKey: "list_view_column_order", default: "")
        let savedTokens = Set(
            orderRaw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        )
        columnOrder = orderRaw.isEmpty ? ImageListColumnID.defaultOrder : Self.parseOrder(orderRaw)
        let hiddenRaw = config.string(forKey: "list_view_hidden_columns", default: "comments,ext")
        hiddenColumns = Self.parseHidden(hiddenRaw)
        hiddenColumns.remove(.thumbnail)
        if !orderRaw.isEmpty, !savedTokens.contains(ImageListColumnID.ext.rawValue) {
            hiddenColumns.insert(.ext)
        }
        columnOrder = Self.mergeOrder(columnOrder)
    }

    func save(to config: AppConfig, eventBus: AppEventBus) {
        config.updateSetting("list_view_column_order", value: columnOrder.map(\.rawValue).joined(separator: ","))
        let hidden = hiddenColumns.subtracting([.thumbnail]).map(\.rawValue).sorted().joined(separator: ",")
        config.updateSetting("list_view_hidden_columns", value: hidden)
        config.applySettingsChange(emit: eventBus)
    }

    func setColumnVisible(_ column: ImageListColumnID, visible: Bool) {
        guard column.canHide else { return }
        if visible {
            hiddenColumns.remove(column)
        } else {
            hiddenColumns.insert(column)
        }
    }

    func isColumnVisible(_ column: ImageListColumnID) -> Bool {
        !hiddenColumns.contains(column)
    }

    /// Restore default column order; visibility (hidden columns) is unchanged.
    func applyDefaultColumnOrder() {
        columnOrder = ImageListColumnID.defaultOrder
    }

    func syncOrderFromTableColumns(_ tableView: NSTableView) {
        let visibleFromTable = tableView.tableColumns.compactMap {
            ImageListColumnID(rawValue: $0.identifier.rawValue)
        }
        guard !visibleFromTable.isEmpty else { return }
        var newOrder: [ImageListColumnID] = []
        var tableIndex = 0
        for col in columnOrder {
            if hiddenColumns.contains(col) {
                newOrder.append(col)
            } else if tableIndex < visibleFromTable.count {
                newOrder.append(visibleFromTable[tableIndex])
                tableIndex += 1
            }
        }
        while tableIndex < visibleFromTable.count {
            newOrder.append(visibleFromTable[tableIndex])
            tableIndex += 1
        }
        columnOrder = Self.mergeOrder(newOrder)
    }

    private static func parseOrder(_ raw: String) -> [ImageListColumnID] {
        let parts = raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        var order: [ImageListColumnID] = []
        for part in parts {
            if let id = ImageListColumnID(rawValue: part), !order.contains(id) {
                order.append(id)
            }
        }
        return mergeOrder(order)
    }

    private static func parseHidden(_ raw: String) -> Set<ImageListColumnID> {
        guard !raw.isEmpty else { return [] }
        return Set(
            raw.split(separator: ",").compactMap {
                ImageListColumnID(rawValue: String($0).trimmingCharacters(in: .whitespaces))
            }
        )
    }

    private static func mergeOrder(_ order: [ImageListColumnID]) -> [ImageListColumnID] {
        var merged = order.filter { ImageListColumnID.defaultOrder.contains($0) }
        for id in ImageListColumnID.defaultOrder where !merged.contains(id) {
            let defaultIndex = ImageListColumnID.defaultOrder.firstIndex(of: id) ?? merged.count
            var insertAt = merged.count
            if defaultIndex > 0 {
                let predecessor = ImageListColumnID.defaultOrder[defaultIndex - 1]
                if let predIdx = merged.firstIndex(of: predecessor) {
                    insertAt = predIdx + 1
                }
            } else {
                insertAt = 0
            }
            merged.insert(id, at: min(insertAt, merged.count))
        }
        return merged
    }
}
