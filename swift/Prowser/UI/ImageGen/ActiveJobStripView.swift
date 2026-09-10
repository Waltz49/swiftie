import SwiftUI

@MainActor
struct ActiveJobStripView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let controller = appState.imageGen
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(controller.progressMessage.isEmpty ? "Generating…" : controller.progressMessage)
                .font(.caption)
                .lineLimit(1)
            Spacer()
            Button("Cancel") {
                controller.cancelActiveJob()
            }
            .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}
