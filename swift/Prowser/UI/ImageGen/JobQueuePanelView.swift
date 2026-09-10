import AppKit
import SwiftUI

@MainActor
struct JobQueuePanelView: View {
    @Environment(AppState.self) private var appState

    var compactForFloating: Bool = false

    var body: some View {
        let controller = appState.imageGen
        let mode = appState.jobsQueueSizeMode

        VStack(alignment: .leading, spacing: 8) {
            if !compactForFloating, controller.isProcessing {
                ActiveJobStripView()
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

            if !controller.progressMessage.isEmpty, mode != .strip {
                Text(controller.progressMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let preview = controller.progressivePreviewPath, mode == .all {
                progressivePreviewView(path: preview)
            }
            if !controller.lastError.isEmpty {
                Text(controller.lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(compactForFloating ? 10 : 8)
        .frame(
            minHeight: mode.estimatedContentHeight(
                jobCount: controller.queueSnapshot().count,
                isProcessing: controller.isProcessing
            ),
            alignment: .top
        )
        .onChange(of: controller.queueRevision) { _, _ in }
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

    @ViewBuilder
    private func queueContent(mode: JobsQueueSizeMode) -> some View {
        switch mode {
        case .strip:
            ActiveJobStripView()
        case .one, .all:
            JobQueuePanelNSViewRepresentable(compactForFloating: compactForFloating)
                .frame(minHeight: 80)
        }
    }

    @ViewBuilder
    private func progressivePreviewView(path: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text((path as NSString).lastPathComponent)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture {
                        appState.openGeneratedImageInBrowse(path: path)
                    }
            }
        }
    }
}
