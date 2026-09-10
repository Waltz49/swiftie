import Foundation

/// Mirrors Python `sort_mode.SortMode`.
enum SortMode: String, CaseIterable, Sendable {
    case date
    case exifDate = "exif_date"
    case exifYear = "exif_year"
    case name
    case size
    case filesize
    case dimensions
    case permissions
    case custom
    case random
    case duplicates

    var displayName: String {
        switch self {
        case .date: return "Date"
        case .exifDate: return "EXIF Date"
        case .exifYear: return "EXIF Year"
        case .name: return "Name"
        case .size: return "Size"
        case .filesize: return "File Size"
        case .dimensions: return "Dimensions"
        case .permissions: return "Permissions"
        case .custom: return "Custom"
        case .random: return "Random"
        case .duplicates: return "Duplicates"
        }
    }
}
