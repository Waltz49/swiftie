import AppKit
import CoreGraphics
import Foundation

extension AppState {
    /// Coalesce resize requests to one pass after layout (no multi-step grow/shrink loop).
    func scheduleJobsPaneGeometryRefit() {
        let snapping = jobsSurfaceExactSnapPasses > 0
        guard snapping || jobsDisplayMode == .pane else { return }
        if rightSidebarSplit.userPaneResizeInProgress || isAdjustingJobsPaneGeometry {
            jobsPaneRefitDeferred = true
        }
        jobsPaneResizeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.jobsPaneResizeDebounce = nil
            if self.isAdjustingJobsPaneGeometry {
                self.jobsPaneRefitDeferred = true
                DispatchQueue.main.async { [weak self] in
                    self?.scheduleJobsPaneGeometryRefit()
                }
                return
            }
            if self.rightSidebarSplit.userPaneResizeInProgress {
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
                    return
                }
            }
            guard self.jobsDisplayMode == .pane else { return }
            let forceRefit = self.jobsPaneGeometryForceRefit
            self.jobsPaneGeometryForceRefit = false
            if !self.shouldInvokeJobsPaneEnsureFitsRefit(forceRefit: forceRefit) {
                return
            }
            self.rightSidebarSplit.ensureJobsPaneFitsContent(appState: self, forceRefit: forceRefit)
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
        let count = visibleJobsQueueRowCount()
        let expected = jobsQueueSizeMode == .one ? min(1, count) : count
        return host.panel.displayedRowCount == expected
    }

    /// Floating Job Control window height using the same measured body as the sidebar pane.
    func floatingJobsPanelContentHeight() -> CGFloat {
        var height = jobsPaneTargetPaneHeight()
        let floatingToolbar = jobsToolbarVisible && !jobsPaneMiniChromeActive
        if floatingToolbar {
            height += JobQueuePaneMetrics.toolbarBlockHeight
        }
        return height
    }

    /// Jobs titlebar height for the active surface: 0 in Mini ⌥[ mode (sidebar or floating).
    private func effectiveJobsPaneHeaderHeight() -> CGFloat {
        if jobsPaneMiniChromeActive,
           jobsDisplayMode == .pane || showFloatingJobsPanel {
            return 0
        }
        return SidebarPaneLayout.headerHeight
    }

    private func jobsQueueActionToolbarShownForSizing() -> Bool {
        guard jobsToolbarVisible, !jobsPaneMiniChromeActive else { return false }
        return jobsDisplayMode == .pane || showFloatingJobsPanel
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
        guard jobsQueueCardDetailsReadyForSizing() else { return }
        let tolerance = SidebarPaneLayout.paneFitHeightTolerance(needed: panelHeight)
        guard abs(jobsQueuePanelIntrinsicHeight - panelHeight) > tolerance else { return }
        jobsQueuePanelIntrinsicHeight = panelHeight
        guard shouldScheduleJobsPaneRefitForContentChange(onQueueChange: true) else { return }
        scheduleJobsPaneGeometryRefit()
    }

    /// Port of Python ``auto_sidebar_pane_content_height`` / ``prepare_size_measure`` gating:
    /// do not shrink the jobs pane from stale zeros or default card heights.
    func jobsPaneFitMeasurementsReady() -> Bool {
        let mode = jobsQueueSizeMode
        let jobCount = visibleJobsQueueRowCount()
        let showsStrip = imageGen.isProcessing || imageGen.cooldownSecondsRemaining > 0

        if mode == .strip {
            if !showsStrip { return true }
            if measuredActiveJobStripHeight > 0 { return true }
            return JobQueuePaneMetrics.estimatedActiveStripHeight(for: imageGen.activeStripView) > 28
        }

        if jobCount == 0 {
            if !showsStrip { return true }
            return measuredActiveJobStripHeight > 0
                || JobQueuePaneMetrics.estimatedActiveStripHeight(for: imageGen.activeStripView) > 28
        }

        guard let host = jobsQueuePanelMeasureHost else { return false }
        let panel = host.panel
        if panel.isLaidOutAtPlaceholderWidth { return false }
        let expected = mode == .one ? min(1, jobCount) : jobCount
        if panel.displayedRowCount != expected { return false }

        guard jobsQueueCardDetailsReadyForSizing() else { return false }

        let queueBlock = max(jobsQueuePanelIntrinsicHeight, measuredJobsCardStackHeight)
        let actionBarFloor = 40 + JobQueueLayout.actionBarHeight
        guard queueBlock > actionBarFloor else { return false }

        if showsStrip, measuredActiveJobStripHeight <= 0 {
            return JobQueuePaneMetrics.estimatedActiveStripHeight(for: imageGen.activeStripView) > 28
        }
        return true
    }

    /// Sidebar jobs pane body height from live AppKit measurements (not formula estimates).
    func jobsPaneLiveContentHeight() -> CGFloat {
        let mode = jobsQueueSizeMode
        let jobCount = visibleJobsQueueRowCount()
        let shrinkWrap = shouldShrinkWrapJobsClient()
        let showsStrip = imageGen.isProcessing || imageGen.cooldownSecondsRemaining > 0
        let toolbarShown = jobsQueueActionToolbarShownForSizing()
        let toolbar = toolbarShown ? JobQueuePaneMetrics.toolbarBlockHeight : 0
        let statusBarHeight = effectiveStatusBarHeight

        if shrinkWrap {
            let bottom = JobQueuePaneMetrics.paneAutoResizeBottomInset(
                mode: mode,
                shrinkWrap: true,
                jobCount: jobCount,
                viewBorderWidthPx: theme.colors.viewBorderWidthPx,
                statusBarHeight: statusBarHeight
            )
            let padding = JobQueuePaneMetrics.panelPadding * 2
            if mode == .strip {
                return padding
                    + JobQueuePaneMetrics.emptyStateClientHeight(toolbarVisible: toolbarShown)
                    + bottom
            }
            return toolbar + padding + JobQueuePaneMetrics.emptyQueueLabelHeight + bottom
        }

        var body = JobQueuePaneMetrics.panelPadding * 2

        if showsStrip {
            let stripEstimate = JobQueuePaneMetrics.estimatedActiveStripHeight(for: imageGen.activeStripView)
            body += max(measuredActiveJobStripHeight, stripEstimate, 28)
            if mode != .strip, jobCount > 0 || imageGen.isProcessing {
                body += JobQueuePaneMetrics.vstackSpacing
            }
        }

        if mode != .strip {
            var queueBlock = max(jobsQueuePanelIntrinsicHeight, measuredJobsCardStackHeight)
            if jobCount > 0, let host = jobsQueuePanelMeasureHost {
                let width = host.panel.layoutViewportWidth()
                if width > 1 {
                    queueBlock = max(
                        queueBlock,
                        host.panel.intrinsicPanelBlockHeight(mode: mode, layoutWidth: width)
                    )
                }
            }
            if jobCount > 0 {
                if queueBlock > 0 {
                    body += max(queueBlock, 40)
                }
            } else if queueBlock > 0 {
                body += queueBlock
            }
        }

        let bottom = JobQueuePaneMetrics.paneAutoResizeBottomInset(
            mode: mode,
            shrinkWrap: false,
            jobCount: jobCount,
            viewBorderWidthPx: theme.colors.viewBorderWidthPx,
            statusBarHeight: statusBarHeight
        )

        return toolbar + body + bottom
    }

    func jobsPaneTargetPaneHeight() -> CGFloat {
        let header = effectiveJobsPaneHeaderHeight()
        let content = jobsPaneLiveContentHeight()
        if shouldShrinkWrapJobsClient() {
            return header + content
        }
        return header + max(content, SidebarPaneLayout.minJobsQueueContentHeight)
    }

    /// Port of ``_jobs_compact_pane_height`` body (header + strip-mode client height).
    func jobsCompactPaneHeight() -> CGFloat {
        effectiveJobsPaneHeaderHeight() + jobsStripCompactContentHeight()
    }

    /// True when titlebar drag can snap jobs pane to strip floor (``_jobs_strip_compact_available``).
    func jobsStripCompactAvailable() -> Bool {
        guard jobsDisplayMode == .pane else { return false }
        guard !rightSidebarSplit.jobsIsSoleVisiblePane(appState: self) else { return false }
        let header = effectiveJobsPaneHeaderHeight()
        return jobsCompactPaneHeight() > header + 1
    }

    private func jobsStripCompactContentHeight() -> CGFloat {
        let toolbarShown = jobsQueueActionToolbarShownForSizing() && jobsDisplayMode == .pane
        let toolbar = toolbarShown ? JobQueuePaneMetrics.toolbarBlockHeight : 0
        let padding = JobQueuePaneMetrics.panelPadding * 2
        let showsStrip = imageGen.isProcessing || imageGen.cooldownSecondsRemaining > 0
        if showsStrip {
            let stripEstimate = JobQueuePaneMetrics.estimatedActiveStripHeight(for: imageGen.activeStripView)
            let strip = max(measuredActiveJobStripHeight, stripEstimate, 28)
            return toolbar + padding + strip
        }
        return toolbar + padding + JobQueuePaneMetrics.emptyStateClientHeight(toolbarVisible: toolbarShown)
    }

    /// Port of ``JobQueuePanelWidget._deferred_generation_geometry_sync`` + ⌘\\ re-apply current mode.
    func scheduleJobsPaneLayoutSettleRefresh() {
        guard jobsDisplayMode == .pane else { return }
        jobsPaneLayoutSettleToken += 1
        let token = jobsPaneLayoutSettleToken
        let delaysMs: [Int] = [0, 50, 200]
        for (index, delayMs) in delaysMs.enumerated() {
            let finalPass = index == delaysMs.count - 1
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
                self?.performJobsPaneLayoutSettleRefresh(expectedToken: token, finalPass: finalPass)
            }
        }
    }

    private func performJobsPaneLayoutSettleRefresh(expectedToken: Int, finalPass: Bool) {
        guard expectedToken == jobsPaneLayoutSettleToken else { return }
        guard jobsDisplayMode == .pane else { return }
        jobsQueuePanelSync?()
        jobsQueueStripMeasureRefresh?()
        guard finalPass else { return }
        refreshJobsPaneLiveMeasurements()
        jobsPaneGeometryForceRefit = true
        scheduleJobsPaneGeometryRefit()
    }

    func refreshJobsPaneLiveMeasurements() {
        jobsQueueStripMeasureRefresh?()
        jobsQueuePanelSync?()
        guard let host = jobsQueuePanelMeasureHost else { return }
        let width = host.panel.layoutViewportWidth()
        let mode = jobsQueueSizeMode
        noteJobsQueuePanelMeasurement(
            panelHeight: host.panel.intrinsicPanelBlockHeight(mode: mode, layoutWidth: width)
        )
    }
}
