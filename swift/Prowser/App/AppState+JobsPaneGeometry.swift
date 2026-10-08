import AppKit
import CoreGraphics
import Foundation

extension AppState {
    /// Coalesce resize requests to one pass after layout (no multi-step grow/shrink loop).
    func scheduleJobsPaneGeometryRefit() {
        let snapping = jobsSurfaceExactSnapPasses > 0
        guard snapping || jobsDisplayMode == .pane else { return }
        if isAdjustingJobsPaneGeometry {
            jobsPaneRefitDeferred = true
            return
        }
        jobsPaneResizeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.jobsPaneResizeDebounce = nil
            if self.isAdjustingJobsPaneGeometry {
                self.jobsPaneRefitDeferred = true
                return
            }
            if self.jobsSurfaceExactSnapPasses > 0 {
                self.jobsSurfaceExactSnapPasses -= 1
                let lastPass = self.jobsSurfaceExactSnapPasses == 0
                if self.applyJobsSurfaceExactSnap(allowIncomplete: lastPass) || lastPass {
                    self.jobsSurfaceExactSnapPasses = 0
                } else {
                    self.scheduleJobsPaneGeometryRefit()
                }
                return
            }
            guard self.jobsDisplayMode == .pane else { return }
            self.rightSidebarSplit.resizeJobsPaneToMode(appState: self)
        }
        jobsPaneResizeDebounce = work
        DispatchQueue.main.async(execute: work)
    }

    /// Shortcut snap: set the showing pane or panel to ``jobsPaneTargetPaneHeight``.
    /// Returns false when the queue rows for the new mode are not laid out yet.
    private func applyJobsSurfaceExactSnap(allowIncomplete: Bool) -> Bool {
        guard allowIncomplete || jobsSurfaceSnapMeasurementsReady() else { return false }
        if showFloatingJobsPanel {
            return resizeFloatingJobsPanelToOptimal()
        }
        guard jobsDisplayMode == .pane else { return true }
        rightSidebarSplit.snapJobsPaneToMeasuredHeight(appState: self)
        return true
    }

    private func jobsSurfaceSnapMeasurementsReady() -> Bool {
        if jobsQueueSizeMode == .strip || imageGen.queue.jobs.isEmpty { return true }
        guard let host = jobsQueuePanelMeasureHost else { return false }
        let count = imageGen.queue.jobs.count
        let expected = jobsQueueSizeMode == .one ? min(1, count) : count
        return host.panel.displayedRowCount == expected
    }

    /// Floating Job Control window height using the same measured body as the sidebar pane.
    func floatingJobsPanelContentHeight() -> CGFloat {
        var height = jobsPaneTargetPaneHeight()
        if jobsToolbarVisible {
            height += JobQueuePaneMetrics.toolbarBlockHeight
        }
        return height
    }

    @discardableResult
    private func resizeFloatingJobsPanelToOptimal() -> Bool {
        guard let window = SceneWindowChrome.jobsPanelWindow(), window.isVisible else { return false }
        refreshJobsPaneLiveMeasurements()
        let target = max(floatingJobsPanelContentHeight(), 80)
        let frame = window.frame
        var height = target
        let margin: CGFloat = 8
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        if let screen {
            height = min(height, screen.height - 2 * margin)
        }
        window.minSize = NSSize(width: max(window.minSize.width, 260), height: 80)
        var newFrame = frame
        newFrame.size.height = height
        if let screen {
            let maxBottom = screen.maxY - margin
            if newFrame.maxY > maxBottom {
                newFrame.origin.y = maxBottom - height
            }
            if newFrame.origin.y < screen.minY + margin {
                newFrame.origin.y = screen.minY + margin
                height = min(height, maxBottom - newFrame.origin.y)
                newFrame.size.height = height
            }
        }
        window.setFrame(newFrame, display: true)
        return true
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
