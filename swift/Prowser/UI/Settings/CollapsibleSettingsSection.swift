import SwiftUI

/// Expandable settings section — port of `CollapsibleThemeGroup`.
struct CollapsibleSettingsSection<Content: View>: View {
    let title: String
    let stateKey: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Text(title)
                        .font(.headline)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    content()
                }
                .padding(.top, 8)
                .padding(.leading, 18)
            }
        }
        .padding(.vertical, 4)
    }
}
