import SwiftUI

/// Status bar section layout (Python `status_bar_config.StatusBarConfig` / `_apply_layout`).
enum StatusBarLayout {
    enum SectionID: CaseIterable {
        case sort
        case filter
        case filename
        case dimensions
        case date
        case fitMode
        case fileCount

        /// Python `section_order` in `_apply_layout`.
        static let displayOrder: [SectionID] = [
            .sort, .filter, .filename, .dimensions, .date, .fitMode, .fileCount,
        ]

        /// Minimum width hint as percent of bar width (`width_percent` in Python config).
        var widthPercent: CGFloat {
            switch self {
            case .sort: return 10
            case .filter: return 12
            case .filename: return 25
            case .dimensions: return 10
            case .date: return 16
            case .fitMode: return 10
            case .fileCount: return 8
            }
        }

        /// Python separator after each section except file count.
        var showsSeparatorAfter: Bool {
            self != .fileCount
        }

        var expands: Bool {
            self == .filename
        }

        var alignment: Alignment {
            switch self {
            case .filename:
                return .leading
            case .sort, .filter, .dimensions, .date, .fitMode, .fileCount:
                return .center
            }
        }

        var isBold: Bool {
            self == .filename
        }
    }

    static func minWidth(for section: SectionID, totalWidth: CGFloat) -> CGFloat {
        max(40, totalWidth * section.widthPercent / 100)
    }
}

struct StatusBarSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color(red: 0.33, green: 0.33, blue: 0.33))
            .frame(width: 3, height: 20)
    }
}
