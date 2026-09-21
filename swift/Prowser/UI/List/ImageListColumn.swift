import AppKit
import Foundation

/// Identifies a list-view column. Add new cases here when introducing categories.
enum ImageListColumnID: String, CaseIterable, Codable, Sendable {
    case thumbnail
    case permissions
    case date
    case size
    case dimensions
    case name

    static let defaultOrder: [ImageListColumnID] = [
        .thumbnail, .permissions, .date, .size, .dimensions, .name,
    ]

    var title: String {
        switch self {
        case .thumbnail: return ""
        case .permissions: return "Perm"
        case .date: return "Date"
        case .size: return "Size"
        case .dimensions: return "Dim"
        case .name: return "Name"
        }
    }

    var menuTitle: String {
        switch self {
        case .thumbnail: return "Thumbnail"
        case .permissions: return "Permissions"
        case .date: return "Date"
        case .size: return "Size"
        case .dimensions: return "Dimensions"
        case .name: return "Name"
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
        case .name: return .name
        }
    }

    var canHide: Bool {
        self != .thumbnail
    }

    var defaultWidth: CGFloat {
        switch self {
        case .thumbnail: return 96
        case .permissions: return 70
        case .date: return 130
        case .size: return 70
        case .dimensions: return 100
        case .name: return 200
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .thumbnail: return 56
        case .name: return 80
        default: return 48
        }
    }

    var textAlignment: NSTextAlignment {
        switch self {
        case .permissions, .size, .dimensions:
            return .center
        case .date:
            return .right
        case .name, .thumbnail:
            return .left
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
        hiddenColumns = []
    }

    func load(from config: AppConfig) {
        let orderRaw = config.string(forKey: "list_view_column_order", default: "")
        columnOrder = orderRaw.isEmpty ? ImageListColumnID.defaultOrder : Self.parseOrder(orderRaw)
        let hiddenRaw = config.string(forKey: "list_view_hidden_columns", default: "")
        hiddenColumns = Self.parseHidden(hiddenRaw)
        hiddenColumns.remove(.thumbnail)
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
        var merged = order
        for id in ImageListColumnID.defaultOrder where !merged.contains(id) {
            merged.append(id)
        }
        return merged
    }
}
