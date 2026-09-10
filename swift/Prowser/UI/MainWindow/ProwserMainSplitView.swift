import AppKit
import SwiftUI

/// NSSplitView that notifies when it has a non-zero width (avoids layout at {{0,0}}).
private final class ProwserSplitView: NSSplitView {
    var onDidLayoutWithWidth: (() -> Void)?
    private var lastNotifiedWidth: CGFloat = 0

    override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 1, abs(width - lastNotifiedWidth) > 0.5 else { return }
        lastNotifiedWidth = width
        onDidLayoutWithWidth?()
    }
}

/// Three-column main window layout with reliable sidebar collapse (Qt `main_splitter` parity).
struct ProwserMainSplitView<Left: View, Center: View, Right: View>: NSViewRepresentable {
    var leftVisible: Bool
    var rightVisible: Bool
    var preferredLeftWidth: CGFloat
    var preferredRightWidth: CGFloat
    var layoutRevision: Int
    var onLeftWidthChange: (CGFloat) -> Void
    var onRightWidthChange: (CGFloat) -> Void
    var onLayoutApplied: () -> Void
    @ViewBuilder var left: () -> Left
    @ViewBuilder var center: () -> Center
    @ViewBuilder var right: () -> Right

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = ProwserSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autoresizesSubviews = true
        splitView.delegate = context.coordinator

        let leftHost = NSHostingView(rootView: left())
        let centerHost = NSHostingView(rootView: center())
        let rightHost = NSHostingView(rootView: right())

        for host in [leftHost, centerHost, rightHost] {
            host.setContentHuggingPriority(.defaultLow, for: .horizontal)
            host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        splitView.addArrangedSubview(leftHost)
        splitView.addArrangedSubview(centerHost)
        splitView.addArrangedSubview(rightHost)

        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(800), forSubviewAt: 1)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 2)

        context.coordinator.splitView = splitView
        context.coordinator.leftHost = leftHost
        context.coordinator.centerHost = centerHost
        context.coordinator.rightHost = rightHost

        splitView.onDidLayoutWithWidth = { [weak coordinator = context.coordinator] in
            coordinator?.scheduleApplyLayout()
        }
        context.coordinator.scheduleApplyLayout()
        return splitView
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        let coordinator = context.coordinator
        let layoutInputsChanged =
            coordinator.lastLeftVisible != leftVisible
            || coordinator.lastRightVisible != rightVisible
            || coordinator.lastLayoutRevision != layoutRevision
            || abs(coordinator.lastPreferredLeftWidth - preferredLeftWidth) > 0.5
            || abs(coordinator.lastPreferredRightWidth - preferredRightWidth) > 0.5

        coordinator.parent = self
        coordinator.leftHost?.rootView = left()
        coordinator.centerHost?.rootView = center()
        coordinator.rightHost?.rootView = right()

        coordinator.lastLeftVisible = leftVisible
        coordinator.lastRightVisible = rightVisible
        coordinator.lastLayoutRevision = layoutRevision
        coordinator.lastPreferredLeftWidth = preferredLeftWidth
        coordinator.lastPreferredRightWidth = preferredRightWidth

        if layoutInputsChanged {
            coordinator.scheduleApplyLayout()
        }
    }

    final class Coordinator: NSObject, NSSplitViewDelegate {
        var parent: ProwserMainSplitView
        weak var splitView: NSSplitView?
        weak var leftHost: NSHostingView<Left>?
        weak var centerHost: NSHostingView<Center>?
        weak var rightHost: NSHostingView<Right>?

        var lastLeftVisible = true
        var lastRightVisible = true
        var lastLayoutRevision = -1
        var lastPreferredLeftWidth: CGFloat = 0
        var lastPreferredRightWidth: CGFloat = 0

        private var applyingLayout = false
        private var suppressWidthCallbacks = false
        private var userInitiatedResize = false
        private var layoutRetryCount = 0

        init(parent: ProwserMainSplitView) {
            self.parent = parent
        }

        func scheduleApplyLayout() {
            applyLayoutIfReady()
            DispatchQueue.main.async { [weak self] in
                self?.applyLayoutIfReady()
            }
        }

        func applyLayoutIfReady() {
            guard let splitView, splitView.subviews.count == 3 else { return }
            let total = splitView.bounds.width
            guard total > 1 else {
                scheduleLayoutRetry()
                return
            }
            applyLayout(total: total)
        }

        private func scheduleLayoutRetry() {
            guard layoutRetryCount < 20 else { return }
            layoutRetryCount += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.applyLayoutIfReady()
            }
        }

        private func sidebarWidths(forTotal total: CGFloat) -> (left: CGFloat, right: CGFloat) {
            var leftW = parent.leftVisible
                ? SidebarWidthLimits.clampLeft(parent.preferredLeftWidth)
                : 0
            var rightW = parent.rightVisible
                ? SidebarWidthLimits.clampRight(parent.preferredRightWidth)
                : 0

            if leftW + rightW + SidebarWidthLimits.centerMin > total {
                if parent.leftVisible, parent.rightVisible {
                    let overflow = leftW + rightW + SidebarWidthLimits.centerMin - total
                    let sideTotal = leftW + rightW
                    if sideTotal > 0 {
                        leftW = max(SidebarWidthLimits.leftMin, leftW - overflow * (leftW / sideTotal))
                        rightW = max(SidebarWidthLimits.rightMin, rightW - overflow * (rightW / sideTotal))
                    }
                } else if parent.leftVisible {
                    leftW = max(SidebarWidthLimits.leftMin, total - SidebarWidthLimits.centerMin)
                } else if parent.rightVisible {
                    rightW = max(SidebarWidthLimits.rightMin, total - SidebarWidthLimits.centerMin)
                }
            }
            return (leftW, rightW)
        }

        private func applyLayout(total: CGFloat) {
            guard let splitView, splitView.subviews.count == 3 else { return }

            suppressWidthCallbacks = true
            applyingLayout = true
            defer {
                applyingLayout = false
                DispatchQueue.main.async { [weak self] in
                    self?.suppressWidthCallbacks = false
                }
            }

            leftHost?.isHidden = !parent.leftVisible
            rightHost?.isHidden = !parent.rightVisible

            let widths = sidebarWidths(forTotal: total)
            let leftW = widths.left
            let rightW = widths.right

            splitView.adjustSubviews()

            if parent.leftVisible {
                splitView.setPosition(leftW, ofDividerAt: 0)
            } else {
                splitView.setPosition(0, ofDividerAt: 0)
            }

            if parent.rightVisible {
                let centerW = max(total - leftW - rightW, SidebarWidthLimits.centerMin)
                splitView.setPosition(leftW + centerW, ofDividerAt: 1)
            } else {
                splitView.setPosition(total, ofDividerAt: 1)
            }

            splitView.adjustSubviews()
            splitView.layoutSubtreeIfNeeded()
            centerHost?.needsLayout = true
            centerHost?.layoutSubtreeIfNeeded()

            parent.onLayoutApplied()
        }

        func splitViewWillResizeSubviews(_ notification: Notification) {
            guard !applyingLayout, !suppressWidthCallbacks else { return }
            userInitiatedResize = NSEvent.pressedMouseButtons != 0
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard !applyingLayout, !suppressWidthCallbacks else { return }
            guard userInitiatedResize else { return }
            userInitiatedResize = false
            guard let splitView = notification.object as? NSSplitView else { return }
            guard splitView.subviews.count == 3 else { return }

            let leftFrame = splitView.subviews[0].frame
            let rightFrame = splitView.subviews[2].frame
            if parent.leftVisible, leftFrame.width > 0 {
                parent.onLeftWidthChange(SidebarWidthLimits.clampLeft(leftFrame.width))
            }
            if parent.rightVisible, rightFrame.width > 0 {
                parent.onRightWidthChange(SidebarWidthLimits.clampRight(rightFrame.width))
            }
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMinCoordinate proposedMinimum: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            let total = max(splitView.bounds.width, 0)
            if dividerIndex == 0 {
                return parent.leftVisible ? SidebarWidthLimits.leftMin : 0
            }
            if dividerIndex == 1 {
                guard parent.rightVisible else { return total }
                let leftW = parent.leftVisible ? splitView.subviews[0].frame.width : 0
                return leftW + SidebarWidthLimits.centerMin
            }
            return proposedMinimum
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMaxCoordinate proposedMaximum: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            let total = max(splitView.bounds.width, 0)
            if dividerIndex == 0 {
                guard parent.leftVisible else { return 0 }
                let rightReserved = parent.rightVisible ? SidebarWidthLimits.rightMin : 0
                let maxLeft = min(
                    SidebarWidthLimits.leftMax,
                    total - rightReserved - SidebarWidthLimits.centerMin
                )
                return max(SidebarWidthLimits.leftMin, maxLeft)
            }
            if dividerIndex == 1 {
                guard parent.rightVisible else { return total }
                return total - SidebarWidthLimits.rightMin
            }
            return proposedMaximum
        }
    }
}
