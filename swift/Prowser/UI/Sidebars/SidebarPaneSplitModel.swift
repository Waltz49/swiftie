import CoreGraphics
import Foundation

enum SidebarSplitSide {
    case left
    case right
}

/// Manages persisted vertical pane heights for a combined sidebar.
@Observable
@MainActor
final class SidebarPaneSplitModel {
    let side: SidebarSplitSide
    private unowned let config: AppConfig

    private(set) var sizes: [CGFloat]
    private var fitTargets: [Int: CGFloat] = [:]
    private var dragStartSizes: [CGFloat]?
    private var dragPressY: CGFloat?

    init(side: SidebarSplitSide, config: AppConfig) {
        self.side = side
        self.config = config
        switch side {
        case .left:
            sizes = config.splitterSizes(forKey: "left_splitter_sizes", default: [200, 200, 200])
        case .right:
            sizes = config.splitterSizes(forKey: "shortcuts_splitter_sizes", default: [150, 250, 120])
        }
    }

    var persistenceKey: String {
        switch side {
        case .left: return "left_splitter_sizes"
        case .right: return "shortcuts_splitter_sizes"
        }
    }

    func paneExpanded(configKey: String, default defaultValue: Bool) -> Bool {
        config.bool(forKey: configKey, default: defaultValue)
    }

    func setPaneExpanded(_ expanded: Bool, configKey: String) {
        config.updateSetting(configKey, value: expanded)
    }

    func headerHeight(for paneIndex: Int) -> CGFloat {
        SidebarPaneLayout.headerHeight
    }

    func minHeight(for paneIndex: Int, headerOnly: Bool, appState: AppState) -> CGFloat {
        let header = headerHeight(for: paneIndex)
        switch side {
        case .left:
            if !paneExpanded(configKey: leftExpandedKey(paneIndex), default: leftDefaultExpanded(paneIndex)) {
                return headerOnly ? header : header
            }
            if paneIndex == 1, !headerOnly {
                return header + SidebarPaneLayout.minPreviewContentHeight
            }
        case .right:
            if !paneExpanded(configKey: rightExpandedKey(paneIndex), default: rightDefaultExpanded(paneIndex)) {
                return header
            }
            if paneIndex == 1, !headerOnly {
                return header + SidebarPaneLayout.minInformationContentHeight
            }
            if paneIndex == 2, !headerOnly {
                return jobsPaneHeight(appState: appState, headerOnly: false)
            }
        }
        return SidebarPaneLayout.paneMinHeight(headerHeight: header, headerOnly: headerOnly)
    }

    /// Which left panes are shown in the stacked layout (matches Python `_display_pane_visibility`).
    static func leftDisplayPaneVisibility(appState: AppState) -> [Bool] {
        let chatEnabled = BundleCapabilities.chatUIEnabled
        let chatVisible = chatEnabled
            && appState.config.bool(forKey: "chat_visible", default: false)
        if chatVisible {
            return [false, false, true]
        }
        if appState.fileData.currentViewMode == .browse {
            return [false, false, false]
        }
        return [
            appState.config.bool(forKey: "file_tree_visible", default: true),
            appState.config.bool(forKey: "preview_visible", default: true),
            false,
        ]
    }

    func visibility(appState: AppState) -> [Bool] {
        switch side {
        case .left:
            return Self.leftDisplayPaneVisibility(appState: appState)
        case .right:
            return [
                true,
                true,
                BundleCapabilities.imageGenUIEnabled && appState.jobsDisplayMode == .pane,
            ]
        }
    }

    func expanded(appState: AppState) -> [Bool] {
        switch side {
        case .left:
            return [
                paneExpanded(configKey: "file_tree_visible", default: true),
                paneExpanded(configKey: "preview_visible", default: true),
                paneExpanded(configKey: "chat_visible", default: false),
            ]
        case .right:
            return [
                paneExpanded(configKey: "shortcuts_sidebar_visible", default: true),
                paneExpanded(configKey: "information_sidebar_visible", default: true),
                paneExpanded(configKey: "jobs_visible", default: true)
                    && appState.jobsDisplayMode == .pane,
            ]
        }
    }

    func layoutSizes(totalHeight: CGFloat, appState: AppState) -> [CGFloat] {
        let vis = visibility(appState: appState)
        let exp = expanded(appState: appState)
        return SidebarPaneLayout.scaledSizes(
            saved: sizes,
            visibility: vis,
            expanded: zip(vis, exp).map { shown, expanded in shown && expanded },
            totalHeight: max(totalHeight, 1)
        )
    }

    func applySizes(_ newSizes: [CGFloat], appState: AppState, persist: Bool) {
        guard newSizes.count == 3 else { return }
        sizes = newSizes
        if persist {
            mergePersistedSizes(appState: appState)
        }
    }

    func mergePersistedSizes(appState: AppState) {
        let vis = visibility(appState: appState)
        let exp = expanded(appState: appState)
        var saved = sizes
        for index in 0..<3 where vis[index] && exp[index] && sizes[index] > 0 {
            saved[index] = sizes[index]
        }
        sizes = saved
        config.saveSplitterSizes(persistenceKey, sizes: saved)
    }

    func beginTitlebarDrag(atY: CGFloat) {
        dragStartSizes = sizes
        dragPressY = atY
    }

    func applyTitlebarDrag(paneIndex: Int, currentY: CGFloat, appState: AppState) {
        let vis = visibility(appState: appState)
        let start = dragStartSizes ?? sizes
        let pressY = dragPressY ?? currentY
        let deltaY = currentY - pressY
        guard let updated = SidebarPaneLayout.applyPaneTitlebarDragDelta(
            paneIdx: paneIndex,
            dy: deltaY,
            visibility: vis,
            startSizes: start,
            minHeightForPane: { idx, headerOnly in
                minHeight(for: idx, headerOnly: headerOnly, appState: appState)
            }
        ) else { return }
        sizes = updated
    }

    func endTitlebarDrag(appState: AppState) {
        dragStartSizes = nil
        dragPressY = nil
        mergePersistedSizes(appState: appState)
    }

    func applySplitterDrag(upperIndex: Int, currentY: CGFloat, appState: AppState) {
        let lowerIndex = upperIndex + 1
        applyTitlebarDrag(paneIndex: lowerIndex, currentY: currentY, appState: appState)
    }

    func neededPaneHeight(
        paneIndex: Int,
        appState: AppState,
        contentHeight: CGFloat
    ) -> CGFloat {
        headerHeight(for: paneIndex) + contentHeight
    }

    func togglePaneFit(
        paneIndex: Int,
        appState: AppState,
        contentHeight: CGFloat
    ) {
        if paneIndex == 2, side == .right {
            cycleJobsPaneSize(appState: appState)
            return
        }

        let expandedFlags = expanded(appState: appState)
        if !expandedFlags[paneIndex] {
            setPaneExpanded(true, configKey: side == .left
                ? leftExpandedKey(paneIndex)
                : rightExpandedKey(paneIndex))
        }

        let needed = neededPaneHeight(paneIndex: paneIndex, appState: appState, contentHeight: contentHeight)
        let current = sizes[paneIndex]
        let stored = fitTargets[paneIndex]
        if SidebarPaneLayout.paneHeightAtTarget(current: current, needed: needed, storedTarget: stored) {
            collapsePaneFromFit(paneIndex: paneIndex, appState: appState)
            fitTargets.removeValue(forKey: paneIndex)
            return
        }

        expandPaneToFit(paneIndex: paneIndex, needed: needed, appState: appState)
        fitTargets[paneIndex] = sizes[paneIndex]
    }

    func cycleJobsPaneSize(appState: AppState) {
        guard side == .right, appState.jobsDisplayMode == .pane else { return }
        if !paneExpanded(configKey: "jobs_visible", default: true) {
            setPaneExpanded(true, configKey: "jobs_visible")
        }

        let startHeight = sizes[2]
        let startMode = appState.jobsQueueSizeMode
        appState.applyJobsQueueSizeMode(startMode, forceRefit: true)
        if abs(sizes[2] - startHeight) > SidebarPaneLayout.jobsPaneSizeChangeTolerance {
            mergePersistedSizes(appState: appState)
            return
        }

        var mode = startMode.next()
        while mode != startMode {
            appState.applyJobsQueueSizeMode(mode, forceRefit: false)
            if abs(sizes[2] - startHeight) > SidebarPaneLayout.jobsPaneSizeChangeTolerance {
                mergePersistedSizes(appState: appState)
                return
            }
            mode = mode.next()
        }
        mergePersistedSizes(appState: appState)
    }

    func resizeJobsPaneToMode(appState: AppState) {
        guard side == .right else { return }
        appState.beginJobsPaneGeometryAdjustment()
        defer { appState.endJobsPaneGeometryAdjustment() }

        var previousNeeded: CGFloat = -1
        var previousCurrent: CGFloat = -1
        for _ in 0..<3 {
            let needed = jobsPaneHeight(appState: appState, headerOnly: false)
            let current = sizes[2]
            if previousNeeded >= 0,
               abs(needed - previousNeeded) <= 1,
               abs(current - previousCurrent) <= 1 {
                break
            }
            resizePaneToHeight(paneIndex: 2, targetHeight: needed, appState: appState)
            previousNeeded = needed
            previousCurrent = sizes[2]
        }
    }

    private func jobsPaneHeight(appState: AppState, headerOnly: Bool) -> CGFloat {
        let header = headerHeight(for: 2)
        if headerOnly { return header }
        let content = appState.jobsQueuePaneContentHeight()
        return header + max(content, SidebarPaneLayout.minJobsQueueContentHeight)
    }

    private func expandPaneToFit(paneIndex: Int, needed: CGFloat, appState: AppState) {
        resizePaneToHeight(paneIndex: paneIndex, targetHeight: needed, appState: appState)
    }

    private func collapsePaneFromFit(paneIndex: Int, appState: AppState) {
        let minH = minHeight(for: paneIndex, headerOnly: false, appState: appState)
        resizePaneToHeight(paneIndex: paneIndex, targetHeight: minH, appState: appState)
    }

    private func resizePaneToHeight(paneIndex: Int, targetHeight: CGFloat, appState: AppState) {
        let vis = visibility(appState: appState)
        let total = sizes.reduce(0, +)
        guard total > 0 else { return }
        let collapseFlags = SidebarPaneLayout.collapseFlagsForTarget(
            targetIdx: paneIndex,
            neededTarget: targetHeight,
            total: total,
            visibility: vis,
            minHeightForPane: { idx, headerOnly in
                minHeight(for: idx, headerOnly: headerOnly, appState: appState)
            }
        )
        let updated = SidebarPaneLayout.redistributeForTargetPane(
            paneCount: 3,
            currentSizes: sizes,
            targetIdx: paneIndex,
            neededTarget: targetHeight,
            visibility: vis,
            headerHeightForPane: headerHeight(for:),
            minHeightForPane: { idx, headerOnly in
                minHeight(for: idx, headerOnly: headerOnly, appState: appState)
            },
            totalHeight: total,
            collapseHeaderOnly: collapseFlags
        )
        applySizes(updated, appState: appState, persist: true)
    }

    private func leftExpandedKey(_ paneIndex: Int) -> String {
        switch paneIndex {
        case 0: return "file_tree_visible"
        case 1: return "preview_visible"
        default: return "chat_visible"
        }
    }

    private func rightExpandedKey(_ paneIndex: Int) -> String {
        switch paneIndex {
        case 0: return "shortcuts_sidebar_visible"
        case 1: return "information_sidebar_visible"
        default: return "jobs_visible"
        }
    }

    private func leftDefaultExpanded(_ paneIndex: Int) -> Bool {
        switch paneIndex {
        case 0, 1: return true
        default: return false
        }
    }

    private func rightDefaultExpanded(_ paneIndex: Int) -> Bool {
        true
    }
}
