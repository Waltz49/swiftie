import SwiftUI

/// Status bar section layout (Python `status_bar_config.StatusBarConfig` / `_apply_layout`).
enum StatusBarLayout {
    enum SectionID {
        case sort
        case filter
        case filename
        case dimensions
        case date
        case fitMode
        case fileCount
        case jobIndicator

        /// Python `section_order` in `_apply_layout`.
        static let displayOrder: [SectionID] = [
            .sort, .filter, .filename, .dimensions, .date, .fitMode, .fileCount, .jobIndicator,
        ]

        /// Python separator after each section except the trailing indicator.
        var showsSeparatorAfter: Bool {
            self != .jobIndicator
        }

        var expands: Bool {
            self == .filename
        }

        var alignment: Alignment {
            switch self {
            case .filename:
                return .leading
            case .sort, .filter, .dimensions, .date, .fitMode, .fileCount, .jobIndicator:
                return .center
            }
        }

        var isBold: Bool {
            self == .filename
        }
    }
}

struct StatusBarSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color(red: 0.33, green: 0.33, blue: 0.33))
            .frame(width: 3, height: 20)
    }
}
