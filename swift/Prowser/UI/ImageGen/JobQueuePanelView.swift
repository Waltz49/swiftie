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
        let _ = appState.measuredJobsCardStackHeight
        let controller = appState.imageGen
        let _ = controller.queueRevision
        let mode = appState.jobsQueueSizeMode
        let activeStripStructureKey = controller.activeStripView.structureKey()

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
        .onChange(of: activeStripStructureKey) { _, _ in
            let mode = appState.jobsQueueSizeMode
            if mode == .all, appState.imageGen.queue.jobs.count > 1 { return }
            if mode == .one || mode == .strip {
                appState.syncJobsPaneGeometry()
            }
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
                .onTapGesture {
                    // Python `_on_empty_label_press`: clicking the empty label in the floating
                    // dialog returns jobs to the sidebar pane.
                    if compactForFloating {
                        appState.showJobsPane()
                    }
                }
        }
    }

    private func shouldShowActiveStrip(controller: ImageGenController, mode: JobsQueueSizeMode) -> Bool {
        controller.isProcessing || controller.cooldownSecondsRemaining > 0
    }

    /// Python strip mode: cards hidden; ``queue_hold_compact_message`` only when held and idle.
    @ViewBuilder
    private func stripModeBody(controller: ImageGenController) -> some View {
        if let message = queueHoldCompactMessage(controller: controller) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            EmptyView()
        }
    }

    /// Port of ``ImageGenController.queue_hold_compact_message``.
    private func queueHoldCompactMessage(controller: ImageGenController) -> String? {
        guard controller.holdJobQueue, !shouldShowActiveStrip(controller: controller, mode: .strip) else { return nil }
        let jobCount = controller.queueSnapshot().count
        guard jobCount > 0 else { return nil }
        return "Job queue held with \(jobCount) \(jobCount == 1 ? "job" : "jobs")"
    }

    @ViewBuilder
    private func queueContent(mode: JobsQueueSizeMode) -> some View {
        let controller = appState.imageGen
        switch mode {
        case .strip:
            stripModeBody(controller: controller)
        case .one:
            JobQueuePanelNSViewRepresentable(compactForFloating: compactForFloating)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
        case .all:
            if appState.imageGen.queue.jobs.count <= 1 {
                JobQueuePanelNSViewRepresentable(compactForFloating: compactForFloating)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .contentShape(Rectangle())
            } else {
                ExpandingLayout {
                    JobQueuePanelNSViewRepresentable(
                        compactForFloating: compactForFloating,
                        fillsAvailableHeight: true
                    )
                    .contentShape(Rectangle())
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
