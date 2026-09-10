import SwiftUI

/// Disclosure section matching Python ▶/▼ collapse headers.
@MainActor
struct ImageGenCollapsibleSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    var tooltip: String = ""
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(isExpanded ? "▼" : "▶")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tooltip)

            if isExpanded {
                content()
                    .padding(.leading, 18)
            }
        }
    }
}
