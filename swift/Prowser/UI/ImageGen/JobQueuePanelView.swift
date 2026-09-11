import AppKit
import SwiftUI

@MainActor
struct JobQueuePanelView: View {
    @Environment(AppState.self) private var appState

    var compactForFloating: Bool = false

    private var fillsAvailableHeight: Bool {
        appState.jobsQueueSizeMode == .all && appState.imageGen.queue.jobs.count > 1
    }

    var body: some View {
        let _ = appState.imageGenUIRevision
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
        .frame(maxWidth: .infinity, alignment: .top)
        .modifier(JobQueuePanelVerticalSizing(fillsAvailableHeight: fillsAvailableHeight))
        .background(appState.theme.colors.sidebarBackground)
        .onAppear {
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
        case .one:
            JobQueuePanelNSViewRepresentable(compactForFloating: compactForFloating)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        case .all:
            if appState.imageGen.queue.jobs.count <= 1 {
                JobQueuePanelNSViewRepresentable(compactForFloating: compactForFloating)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            } else {
                ExpandingLayout {
                    JobQueuePanelNSViewRepresentable(
                        compactForFloating: compactForFloating,
                        fillsAvailableHeight: true
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

/// Python `_sync_jobs_mode_geometry`: fixed content height (ONE/strip/≤1 job) vs Expanding
/// scroll (ALL + multiple jobs). `fixedSize` proposes nil height so the queue reports its
/// measured height and the pane splitter slice hugs the content.
private struct JobQueuePanelVerticalSizing: ViewModifier {
    let fillsAvailableHeight: Bool

    func body(content: Content) -> some View {
        if fillsAvailableHeight {
            content.frame(maxHeight: .infinity, alignment: .top)
        } else {
            content.fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// ALL mode with multiple jobs: queue scroll fills the splitter slice (Python scroll stretch).
private struct ExpandingLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        subview.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
