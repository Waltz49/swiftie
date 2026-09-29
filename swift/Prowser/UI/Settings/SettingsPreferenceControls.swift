import AppKit
import SwiftUI

// MARK: - Switch (port of MacToggleSwitch)

struct MacPreferenceSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    private let trackWidth: CGFloat = 36
    private let trackHeight: CGFloat = 20
    private let thumbMargin: CGFloat = 2

    func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.isOn
        let trackColor = isOn ? SettingsDialogChrome.switchTrackOn : SettingsDialogChrome.switchTrackOff
        let thumbDiameter = trackHeight - 2 * thumbMargin
        let thumbX = isOn
            ? trackWidth - thumbMargin - thumbDiameter
            : thumbMargin

        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackColor.opacity(isEnabled ? 1 : 0.47))
                    .frame(width: trackWidth, height: trackHeight)
                Circle()
                    .fill(Color.white.opacity(isEnabled ? 1 : 0.71))
                    .overlay {
                        Circle()
                            .strokeBorder(Color.black.opacity(isEnabled ? 0.10 : 0.04), lineWidth: 0.5)
                    }
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .offset(x: thumbX)
            }
            .frame(width: trackWidth, height: trackHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
    }
}

struct SettingsPreferenceSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) { EmptyView() }
            .toggleStyle(MacPreferenceSwitchStyle())
            .labelsHidden()
    }
}

// MARK: - Rows (port of MacPreferenceToggleRow / FormRow / CompactToggleRow)

struct SettingsPreferenceSubsectionHeader: View {
    let title: String
    var trailingNote: String?
    var verticalPadding: CGFloat = 8

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(SettingsDialogChrome.rowTitle)
            if let trailingNote, !trailingNote.isEmpty {
                Text(trailingNote)
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsDialogChrome.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, verticalPadding)
    }
}

struct SettingsPreferenceToggleRow: View {
    let title: String
    var subtitle: String?
    var tooltip: String?
    var verticalPadding: CGFloat = 10
    var leadingInset: CGFloat = 0
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(SettingsDialogChrome.rowTitle)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsDialogChrome.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            SettingsPreferenceSwitch(isOn: $isOn)
        }
        .padding(.leading, 20 + leadingInset)
        .padding(.trailing, 20)
        .padding(.vertical, verticalPadding)
        .help(tooltip ?? title)
    }
}

enum SettingsPreferenceCompactToggleMetrics {
    static let horizontalPadding: CGFloat = 16
    static let labelSwitchSpacing: CGFloat = 8
    static let switchWidth: CGFloat = 36
    static let fontSize: CGFloat = 13

    static func rowWidth(forTitle title: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize)
        let label = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        return horizontalPadding + label + labelSwitchSpacing + switchWidth
    }
}

/// Shared column-major compact toggle grid (root directories, file types, …).
enum SettingsPreferenceCompactToggleGridLayout {
    /// Minimum horizontal gap between columns when distributing across the group box.
    static let columnSpacing: CGFloat = 10

    /// Inset from the group box content edges for the grid.
    static let internalHorizontalPadding: CGFloat = 4

    static func columnWidth(forTitles titles: [String]) -> CGFloat {
        titles
            .map { SettingsPreferenceCompactToggleMetrics.rowWidth(forTitle: $0) }
            .max() ?? 0
    }
}

/// Compact-width columns distributed evenly across available width.
struct SettingsPreferenceCompactToggleColumnGrid<Item: Hashable, RowContent: View>: View {
    let columns: [[Item]]
    let columnRowTitles: (Item) -> String
    @ViewBuilder let row: (Item) -> RowContent

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if !columns.isEmpty {
                Spacer(minLength: 0)
                ForEach(Array(columns.enumerated()), id: \.offset) { index, items in
                    if index > 0 {
                        Spacer(minLength: SettingsPreferenceCompactToggleGridLayout.columnSpacing)
                    }
                    columnStack(items: items)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, SettingsPreferenceCompactToggleGridLayout.internalHorizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func columnStack(items: [Item]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { item in
                row(item)
            }
        }
        .frame(
            width: SettingsPreferenceCompactToggleGridLayout.columnWidth(
                forTitles: items.map(columnRowTitles)
            ),
            alignment: .leading
        )
    }
}

struct SettingsPreferenceCompactToggleRow: View {
    let title: String
    var tooltip: String?
    /// When true, label grows so the switch sits on the trailing edge of the column.
    var expandLabel = true
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: SettingsPreferenceCompactToggleMetrics.labelSwitchSpacing) {
            Text(title)
                .font(.system(size: SettingsPreferenceCompactToggleMetrics.fontSize))
                .foregroundStyle(SettingsDialogChrome.rowTitle)
                .lineLimit(1)
                .frame(maxWidth: expandLabel ? .infinity : nil, alignment: .leading)
            SettingsPreferenceSwitch(isOn: $isOn)
        }
        .padding(.horizontal, SettingsPreferenceCompactToggleMetrics.horizontalPadding / 2)
        .padding(.vertical, 5)
        .frame(maxWidth: expandLabel ? .infinity : nil, alignment: .leading)
        .help(tooltip ?? title)
    }
}

struct SettingsPreferenceFormRow<Control: View>: View {
    let label: String
    var subtitle: String?
    var tooltip: String?
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(SettingsDialogChrome.rowTitle)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsDialogChrome.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            control()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .help(tooltip ?? label)
    }
}

/// Groups preference rows (`MacPreferencePanel`, no row dividers in settings chrome).
struct SettingsPreferencePanel<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
    }
}

// MARK: - Outlined group box (port of QGroupBox / mac_preference_section)

enum SettingsCollapsibleTitlePrefix {
    static let collapsed = "\u{25B6} "  // ▶
    static let expanded = "\u{25BC} "   // ▼
}

struct SettingsOutlinedGroupBox<Title: View, Content: View>: View {
    private let borderWidth: CGFloat = 2
    private let cornerRadius: CGFloat = 4

    @ViewBuilder let title: () -> Title
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(.horizontal, 6)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(SettingsDialogChrome.border, lineWidth: borderWidth)
            }
            .overlay(alignment: .topLeading) {
                title()
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(x: 8, y: -11)
            }
            .padding(.top, 11)
        }
    }
}

@ViewBuilder
func settingsOutlinedGroupBoxTitle(_ title: String) -> some View {
    Text(title)
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(SettingsDialogChrome.groupBoxTitle)
        .padding(.horizontal, 4)
        .background(SettingsDialogChrome.background)
}

/// Column-major grid layout (`build_column_major_toggle_grid` in Python).
enum SettingsColumnMajorGrid {
    static func columnCount(itemCount: Int, preferredColumns: Int = 3) -> Int {
        guard itemCount > 0 else { return 1 }
        let rowsWithPreferred = (itemCount + preferredColumns - 1) / preferredColumns
        let rowsWithFour = (itemCount + 3) / 4
        return rowsWithFour <= rowsWithPreferred ? 4 : preferredColumns
    }

    static func columns(items: [String], columnCount: Int) -> [[String]] {
        let count = items.count
        guard count > 0 else { return [] }
        let cols = max(1, columnCount)
        let rowCount = (count + cols - 1) / cols
        return (0..<cols).map { col in
            (0..<rowCount).compactMap { row -> String? in
                let index = col * rowCount + row
                return index < count ? items[index] : nil
            }
        }
    }
}
