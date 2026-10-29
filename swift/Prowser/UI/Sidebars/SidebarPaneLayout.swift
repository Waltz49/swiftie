import CoreGraphics
import Foundation

/// Port of `thumbnails/sidebar_pane_layout.py`.
enum SidebarPaneLayout {
    static let headerHeight: CGFloat = 30
    static let minPaneContent: CGFloat = 20
    static let minPreviewContentHeight: CGFloat = 64
    static let minInformationContentHeight: CGFloat = 20
    static let minJobsQueueContentHeight: CGFloat = 20
    static let paneFitHeightToleranceMin: CGFloat = 8
    static let jobsPaneSizeChangeTolerance: CGFloat = 10
    /// Max fraction of sidebar alloc height for automatic jobs pane growth when upper panes are visible.
    static let jobsPaneAutoResizeMaxFraction: CGFloat = 0.75

    /// Height of one inter-pane splitter grip (matches Qt `setHandleWidth`).
    static func splitterHandleHeight(viewBorderWidthPx: Int) -> CGFloat {
        CGFloat(max(1, viewBorderWidthPx))
    }

    static func paneFitHeightTolerance(needed: CGFloat) -> CGFloat {
        if needed <= 0 { return paneFitHeightToleranceMin }
        return max(paneFitHeightToleranceMin, needed * 0.02)
    }

    static func paneHeightAtTarget(
        current: CGFloat,
        needed: CGFloat,
        storedTarget: CGFloat?
    ) -> Bool {
        if needed <= 0, storedTarget == nil { return false }
        let ref = needed > 0 ? needed : (storedTarget ?? 0)
        if ref <= 0 { return false }
        let tolerance = paneFitHeightTolerance(needed: ref)
        if let storedTarget, abs(current - storedTarget) <= tolerance { return true }
        return abs(current - needed) <= tolerance
    }

    static func paneMinHeight(headerHeight: CGFloat, headerOnly: Bool = false) -> CGFloat {
        headerOnly ? headerHeight : headerHeight + minPaneContent
    }

    static func collapseOrder(targetIdx: Int, otherIndices: [Int]) -> [Int] {
        let below = otherIndices.filter { $0 > targetIdx }.sorted(by: >)
        let above = otherIndices.filter { $0 < targetIdx }.sorted(by: >)
        return below + above
    }

    static func collapseFlagsForTarget(
        targetIdx: Int,
        neededTarget: CGFloat,
        total: CGFloat,
        visibility: [Bool],
        minHeightForPane: (Int, Bool) -> CGFloat
    ) -> [Int: Bool] {
        let otherIndices = visibility.indices.filter { visibility[$0] && $0 != targetIdx }
        var otherMins: [Int: CGFloat] = [:]
        for index in otherIndices {
            otherMins[index] = minHeightForPane(index, false)
        }
        var flags: [Int: Bool] = [:]
        var maxTarget = total - otherMins.values.reduce(0, +)
        if neededTarget <= maxTarget { return flags }
        for index in collapseOrder(targetIdx: targetIdx, otherIndices: otherIndices) {
            flags[index] = true
            otherMins[index] = minHeightForPane(index, true)
            maxTarget = total - otherMins.values.reduce(0, +)
            if neededTarget <= maxTarget { break }
        }
        return flags
    }

    static func redistributeForTargetPane(
        paneCount: Int,
        currentSizes: [CGFloat],
        targetIdx: Int,
        neededTarget: CGFloat,
        visibility: [Bool],
        headerHeightForPane: (Int) -> CGFloat,
        minHeightForPane: (Int, Bool) -> CGFloat,
        totalHeight: CGFloat,
        collapseHeaderOnly: [Int: Bool] = [:]
    ) -> [CGFloat] {
        guard visibility.indices.contains(targetIdx), visibility[targetIdx] else {
            return currentSizes
        }

        let total = max(totalHeight, 1)
        let otherIndices = visibility.indices.filter { visibility[$0] && $0 != targetIdx }
        let targetHeader = headerHeightForPane(targetIdx)
        let needed = max(neededTarget, paneMinHeight(headerHeight: targetHeader))

        var otherMins: [Int: CGFloat] = [:]
        for index in otherIndices {
            let headerOnly = collapseHeaderOnly[index] ?? false
            otherMins[index] = minHeightForPane(index, headerOnly)
        }

        let maxTarget = total - otherMins.values.reduce(0, +)
        let newTarget = min(needed, max(maxTarget, paneMinHeight(headerHeight: targetHeader)))

        var sizes = currentSizes
        if sizes.count < paneCount {
            sizes.append(contentsOf: Array(repeating: 0, count: paneCount - sizes.count))
        }

        var newSizes = Array(repeating: CGFloat(0), count: paneCount)
        if otherIndices.isEmpty {
            newSizes[targetIdx] = min(needed, total)
        } else {
            newSizes[targetIdx] = newTarget
            let remainder = total - newTarget
            let otherTotal = otherIndices.reduce(CGFloat(0)) { $0 + sizes[$1] }
            if otherTotal > 0 {
                for index in otherIndices {
                    newSizes[index] = max(otherMins[index] ?? 0, remainder * sizes[index] / otherTotal)
                }
            } else {
                let each = remainder / CGFloat(otherIndices.count)
                for index in otherIndices {
                    newSizes[index] = max(otherMins[index] ?? 0, each)
                }
            }
            let drift = total - newSizes.reduce(0, +)
            if drift != 0, let adjust = otherIndices.max(by: { newSizes[$0] < newSizes[$1] }) {
                newSizes[adjust] = max(otherMins[adjust] ?? 0, newSizes[adjust] + drift)
            }
        }
        return newSizes
    }

    static func applyPaneTitlebarDragDelta(
        paneIdx: Int,
        dy: CGFloat,
        visibility: [Bool],
        startSizes: [CGFloat],
        minHeightForPane: (Int, Bool) -> CGFloat
    ) -> [CGFloat]? {
        if paneIdx < 1 || dy == 0 { return nil }
        guard paneIdx < visibility.count, visibility[paneIdx] else { return nil }
        guard paneIdx < startSizes.count else { return nil }
        // Upper neighbor may be hidden (e.g. information collapsed while jobs stays open).
        guard let upper = (0..<paneIdx).reversed().first(where: { visibility[$0] }) else { return nil }

        let minUpper = minHeightForPane(upper, false)
        let minLower = minHeightForPane(paneIdx, false)
        var adjustedDY = dy
        if dy > 0 {
            adjustedDY = min(dy, max(0, startSizes[paneIdx] - minLower))
        } else {
            adjustedDY = max(dy, -max(0, startSizes[upper] - minUpper))
        }
        if adjustedDY == 0 { return nil }

        var sizes = startSizes
        sizes[upper] = startSizes[upper] + adjustedDY
        sizes[paneIdx] = startSizes[paneIdx] - adjustedDY
        return sizes
    }

    static func scaledSizes(
        saved: [CGFloat],
        visibility: [Bool],
        expanded: [Bool],
        totalHeight: CGFloat
    ) -> [CGFloat] {
        let visibleIndices = visibility.indices.filter { visibility[$0] }
        guard !visibleIndices.isEmpty else { return saved }

        if visibleIndices.count == 1 {
            let index = visibleIndices[0]
            return visibility.indices.map { idx in
                if idx == index { return totalHeight }
                return 0
            }
        }

        let effective = visibility.indices.map { idx -> CGFloat in
            guard visibility[idx] else { return 0 }
            if expanded[idx] { return max(saved[idx], headerHeight) }
            return headerHeight
        }
        let totalSaved = effective.reduce(0, +)
        guard totalSaved > 0 else { return effective }

        var scaled = visibility.indices.map { idx -> CGFloat in
            guard visibility[idx] else { return 0 }
            return effective[idx] * totalHeight / totalSaved
        }
        let drift = totalHeight - scaled.reduce(0, +)
        if drift != 0, let last = visibleIndices.last {
            scaled[last] += drift
        }
        return scaled
    }
}
