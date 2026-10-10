import SwiftUI

/// Disclosure section matching Python ▶/▼ collapse headers.
@MainActor
struct ImageGenCollapsibleSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    var tooltip: String = ""
    var contentLeadingPadding: CGFloat = ImageGenInlineFieldLayout.controlIndent
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tooltip)

            if isExpanded {
                content()
                    .padding(.leading, contentLeadingPadding)
            }
        }
    }
}
