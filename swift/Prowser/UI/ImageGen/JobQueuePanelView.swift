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
                HStack {
                    Spacer()
                    Button("Cancel") {
                        controller.cancelActiveJob()
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
            }

            if !controller.isEnabled {
                Text("Image generation requires Python workers and a full build.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if controller.queue.jobs.isEmpty {
                emptyQueueView(isProcessing: controller.isProcessing)
            } else {
                queueContent(mode: mode, controller: controller)
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
                jobCount: controller.queue.jobs.count,
                isProcessing: controller.isProcessing
            ),
            alignment: .top
        )
    }

    @ViewBuilder
    private func emptyQueueView(isProcessing: Bool) -> some View {
        if isProcessing, appState.jobsQueueSizeMode == .strip {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text(appState.imageGen.progressMessage.isEmpty ? "Generating…" : appState.imageGen.progressMessage)
                    .font(.caption)
                    .lineLimit(1)
            }
        } else {
            Text("No jobs in the queue.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func queueContent(mode: JobsQueueSizeMode, controller: ImageGenController) -> some View {
        switch mode {
        case .strip:
            stripView(controller: controller)
        case .one:
            if let job = activeJob(from: controller) {
                jobRow(job)
            } else {
                emptyQueueView(isProcessing: controller.isProcessing)
            }
        case .all:
            List {
                ForEach(controller.queue.jobs) { job in
                    jobRow(job)
                        .swipeActions {
                            Button("Remove", role: .destructive) {
                                controller.removeJob(id: job.jobID)
                            }
                        }
                }
            }
            .listStyle(.plain)
        }
    }

    private func stripView(controller: ImageGenController) -> some View {
        HStack(spacing: 8) {
            if controller.isProcessing {
                ProgressView()
                    .controlSize(.small)
            }
            Text(stripSummary(controller: controller))
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 0)
            if controller.isProcessing {
                Button("Cancel") {
                    controller.cancelActiveJob()
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 4)
    }

    private func stripSummary(controller: ImageGenController) -> String {
        if controller.isProcessing {
            return controller.progressMessage.isEmpty ? "Generating…" : controller.progressMessage
        }
        let count = controller.queue.jobs.count
        return count == 1 ? "1 job queued" : "\(count) jobs queued"
    }

    private func activeJob(from controller: ImageGenController) -> ImageGenQueuedJob? {
        if let activeJobID = controller.activeJobID,
           let job = controller.queue.jobs.first(where: { $0.jobID == activeJobID }) {
            return job
        }
        return controller.queue.jobs.first
    }

    private func jobRow(_ job: ImageGenQueuedJob) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(job.fullPrompt)
                .lineLimit(appState.jobsQueueSizeMode == .one ? 3 : 2)
            Text(job.statusLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
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
            }
        }
    }
}
