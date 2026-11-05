import SwiftUI

enum ImageGenCollapsibleSectionMetrics {
    /// ~1 inch at 72 pt/in (gap before optional header trailing controls).
    static let headerTrailingLeadingGap: CGFloat = 72
}

/// Disclosure section matching Python ▶/▼ collapse headers.
@MainActor
struct ImageGenCollapsibleSection<Content: View, HeaderTrailing: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    var tooltip: String = ""
    var contentLeadingPadding: CGFloat = ImageGenInlineFieldLayout.controlIndent
    /// When true, expanded content uses ``SettingsOutlinedGroupBox`` (settings dialog collapsible groups).
    var useSettingsOutlinedStyle: Bool = false
    /// Fixed space between the disclosure title and ``headerTrailing`` (0 when there is no trailing content).
    var headerTrailingLeadingGap: CGFloat = 0
    @ViewBuilder let headerTrailing: () -> HeaderTrailing
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        isExpanded: Binding<Bool>,
        tooltip: String = "",
        contentLeadingPadding: CGFloat = ImageGenInlineFieldLayout.controlIndent,
        useSettingsOutlinedStyle: Bool = false,
        headerTrailingLeadingGap: CGFloat = 0,
        @ViewBuilder headerTrailing: @escaping () -> HeaderTrailing,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self._isExpanded = isExpanded
        self.tooltip = tooltip
        self.contentLeadingPadding = contentLeadingPadding
        self.useSettingsOutlinedStyle = useSettingsOutlinedStyle
        self.headerTrailingLeadingGap = headerTrailingLeadingGap
        self.headerTrailing = headerTrailing
        self.content = content
    }

    var body: some View {
        if useSettingsOutlinedStyle {
            settingsOutlinedBody
        } else {
            classicBody
        }
    }

    private var classicBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 0) {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text(isExpanded ? "▼" : "▶")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.secondary)
                        Text(title)
                            .font(ImageGenInlineFieldLayout.stackedFieldLabelFont)
                            .foregroundStyle(.primary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tooltip)

                headerTrailing()
                    .padding(.leading, headerTrailingLeadingGap)
            }

            if isExpanded {
                content()
                    .padding(.leading, contentLeadingPadding)
            }
        }
    }

    private var settingsOutlinedBody: some View {
        Group {
            if isExpanded {
                SettingsOutlinedGroupBox(contentFillsAvailableWidth: false) {
                    settingsOutlineHeader(expanded: true)
                        .background(SettingsDialogChrome.background)
                        .help(tooltip.isEmpty ? "Click to collapse section" : tooltip)
                } content: {
                    content()
                }
            } else {
                settingsOutlineHeader(expanded: false)
                    .frame(height: 24)
                    .help(tooltip.isEmpty ? "Click to expand section" : tooltip)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func settingsOutlineHeader(expanded: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isExpanded.toggle()
            }
        } label: {
            settingsOutlineHeaderLabel(expanded: expanded)
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: 20)
        .padding(.horizontal, 4)
    }

    private func settingsOutlineHeaderLabel(expanded: Bool) -> some View {
        let prefix = expanded
            ? SettingsCollapsibleTitlePrefix.expanded
            : SettingsCollapsibleTitlePrefix.collapsed
        return Text("\(prefix)\(title)")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(SettingsDialogChrome.groupBoxTitle)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension ImageGenCollapsibleSection where HeaderTrailing == EmptyView {
    init(
        title: String,
        isExpanded: Binding<Bool>,
        tooltip: String = "",
        contentLeadingPadding: CGFloat = ImageGenInlineFieldLayout.controlIndent,
        useSettingsOutlinedStyle: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            title: title,
            isExpanded: isExpanded,
            tooltip: tooltip,
            contentLeadingPadding: contentLeadingPadding,
            useSettingsOutlinedStyle: useSettingsOutlinedStyle,
            headerTrailing: { EmptyView() },
            content: content
        )
    }
}
