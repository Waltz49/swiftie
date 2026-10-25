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
    /// Fixed space between the disclosure title and ``headerTrailing`` (0 when there is no trailing content).
    var headerTrailingLeadingGap: CGFloat = 0
    @ViewBuilder let headerTrailing: () -> HeaderTrailing
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        isExpanded: Binding<Bool>,
        tooltip: String = "",
        contentLeadingPadding: CGFloat = ImageGenInlineFieldLayout.controlIndent,
        headerTrailingLeadingGap: CGFloat = 0,
        @ViewBuilder headerTrailing: @escaping () -> HeaderTrailing,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self._isExpanded = isExpanded
        self.tooltip = tooltip
        self.contentLeadingPadding = contentLeadingPadding
        self.headerTrailingLeadingGap = headerTrailingLeadingGap
        self.headerTrailing = headerTrailing
        self.content = content
    }

    var body: some View {
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
}

extension ImageGenCollapsibleSection where HeaderTrailing == EmptyView {
    init(
        title: String,
        isExpanded: Binding<Bool>,
        tooltip: String = "",
        contentLeadingPadding: CGFloat = ImageGenInlineFieldLayout.controlIndent,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            title: title,
            isExpanded: isExpanded,
            tooltip: tooltip,
            contentLeadingPadding: contentLeadingPadding,
            headerTrailing: { EmptyView() },
            content: content
        )
    }
}
