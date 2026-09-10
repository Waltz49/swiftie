import SwiftUI

struct ExifBatchRow: Identifiable {
    let id: String
    let path: String
    let filename: String
    let detailLines: [String]
}

struct ExifBatchConfirmationState: Identifiable {
    let id = UUID()
    let title: String
    let infoText: String
    let warningText: String?
    let rows: [ExifBatchRow]
    let confirmLabel: String
    let onConfirm: @MainActor () -> Void
}

@MainActor
struct ExifBatchConfirmationSheet: View {
    let state: ExifBatchConfirmationState
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state.title)
                .font(.title2)

            Text(state.infoText)
                .foregroundStyle(.secondary)

            if let warning = state.warningText {
                Text(warning)
                    .foregroundStyle(.red)
                    .fontWeight(.semibold)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(state.rows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.filename)
                                .fontWeight(.medium)
                            ForEach(row.detailLines, id: \.self) { line in
                                Text(line)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 360)
            .border(Color.secondary.opacity(0.25))

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onDismiss() }
                Button(state.confirmLabel) {
                    state.onConfirm()
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
    }
}
