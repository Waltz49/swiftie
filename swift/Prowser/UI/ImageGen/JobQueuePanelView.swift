import AppKit
import SwiftUI

@MainActor
struct JobQueuePanelView: View {
    @Environment(AppState.self) private var appState

    var compactForFloating: Bool = false

    var body: some View {
        let controller = appState.imageGen
        let mode = appState.jobsQueueSizeMode

        VStack(alignment: .leading, spacing: 4) {
            if shouldShowActiveStrip(controller: controller, mode: mode) {
                ActiveJobStripView(includeQueueJobsRow: mode == .strip)
            }

            if !controller.isEnabled {
                Text("Image generation requires Python workers and a full build.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if controller.queueSnapshot().isEmpty, !controller.isProcessing {
                emptyQueueView
            } else {
                queueContent(mode: mode)
            }

            if !controller.lastError.isEmpty {
                Text(controller.lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(compactForFloating ? 10 : 8)
        .frame(
            minHeight: appState.jobsQueuePaneContentHeight(),
            alignment: .top
        )
        .onChange(of: controller.queueRevision) { _, _ in
            guard mode != .strip else { return }
            appState.syncJobsPaneGeometry()
        }
        .onChange(of: mode) { _, _ in
            appState.syncJobsPaneGeometry()
        }
    }

    @ViewBuilder
    private var emptyQueueView: some View {
        if appState.imageGen.isProcessing, appState.jobsQueueSizeMode == .strip {
            ActiveJobStripView()
        } else {
            Text("No jobs in the queue.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func shouldShowActiveStrip(controller: ImageGenController, mode: JobsQueueSizeMode) -> Bool {
        controller.isProcessing || controller.cooldownSecondsRemaining > 0
    }

    @ViewBuilder
    private func queueContent(mode: JobsQueueSizeMode) -> some View {
        switch mode {
        case .strip:
            EmptyView()
        case .one, .all:
            GeometryReader { geometry in
                JobQueuePanelNSViewRepresentable(
                    compactForFloating: compactForFloating,
                    containerWidth: max(geometry.size.width, 260)
                )
                .frame(width: geometry.size.width, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

}
