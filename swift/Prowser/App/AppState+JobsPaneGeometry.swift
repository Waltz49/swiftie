import CoreGraphics
import Foundation

extension AppState {
    /// Coalesce resize requests to one pass after layout (no multi-step grow/shrink loop).
    func scheduleJobsPaneGeometryRefit() {
        guard jobsDisplayMode == .pane else { return }
        if isAdjustingJobsPaneGeometry {
            jobsPaneRefitDeferred = true
            return
        }
        jobsPaneResizeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.jobsPaneResizeDebounce = nil
            guard self.jobsDisplayMode == .pane else { return }
            if self.isAdjustingJobsPaneGeometry {
                self.jobsPaneRefitDeferred = true
                return
            }
            self.rightSidebarSplit.resizeJobsPaneToMode(appState: self)
        }
        jobsPaneResizeDebounce = work
        DispatchQueue.main.async(execute: work)
    }

    func noteJobsQueuePanelMeasurement(panelHeight: CGFloat) {
        jobsQueuePanelIntrinsicHeight = panelHeight
    }

    /// Sidebar jobs pane body height from live AppKit measurements (not formula estimates).
    func jobsPaneLiveContentHeight() -> CGFloat {
        let mode = jobsQueueSizeMode
        let jobCount = imageGen.queue.jobs.count
        let showsStrip = imageGen.isProcessing || imageGen.cooldownSecondsRemaining > 0
        let toolbar = jobsToolbarVisible && jobsDisplayMode == .pane
            ? JobQueuePaneMetrics.toolbarBlockHeight
            : 0

        var body = JobQueuePaneMetrics.panelPadding * 2

        if showsStrip {
            body += max(measuredActiveJobStripHeight, 28)
            if mode != .strip, jobCount > 0 || imageGen.isProcessing {
                body += JobQueuePaneMetrics.vstackSpacing
            }
        }

        if mode != .strip {
            body += max(jobsQueuePanelIntrinsicHeight, measuredJobsCardStackHeight, 40)
        }

        let bottom = JobQueuePaneMetrics.paneAutoResizeBottomInset(
            mode: mode,
            shrinkWrap: shouldShrinkWrapJobsClient(),
            jobCount: jobCount,
            viewBorderWidthPx: theme.colors.viewBorderWidthPx
        )

        return toolbar + body + bottom
    }

    func jobsPaneTargetPaneHeight() -> CGFloat {
        let header = SidebarPaneLayout.headerHeight
        let content = jobsPaneLiveContentHeight()
        return header + max(content, SidebarPaneLayout.minJobsQueueContentHeight)
    }

    func refreshJobsPaneLiveMeasurements() {
        jobsQueueStripMeasureRefresh?()
        jobsQueuePanelSync?()
        guard let host = jobsQueuePanelMeasureHost else { return }
        let width = host.bounds.width > 1 ? host.bounds.width : 280
        let mode = jobsQueueSizeMode
        jobsQueuePanelIntrinsicHeight = host.panel.intrinsicPanelBlockHeight(mode: mode, layoutWidth: width)
    }
}
