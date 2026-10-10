import AppKit
import SwiftUI

/// NSSplitView divider metrics (preview | controls).
enum ImageGenPreviewSplitterMetrics {
    /// Visible width of the draggable split divider.
    static let dividerThickness: CGFloat = 15
}

/// Horizontal preview | controls splitter (Python ``ImageGenPreviewSplitter``).
struct ImageGenPreviewSplitter<Preview: View, Controls: View>: NSViewRepresentable {
    var maxLeftRatio: CGFloat = 0.7
    var initialLeftRatio: CGFloat = 0.5
    var controlsMinWidth: CGFloat = 300
    @ViewBuilder var preview: () -> Preview
    @ViewBuilder var controls: () -> Controls

    func makeCoordinator() -> Coordinator {
        Coordinator(
            maxLeftRatio: maxLeftRatio,
            initialLeftRatio: initialLeftRatio,
            controlsMinWidth: controlsMinWidth
        )
    }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = ImageGenPreviewSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .paneSplitter
        splitView.autoresizesSubviews = true
        splitView.delegate = context.coordinator

        let previewHost = NSHostingView(rootView: preview())
        let controlsHost = NSHostingView(rootView: controls())
        previewHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
        controlsHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
        controlsHost.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        splitView.addArrangedSubview(previewHost)
        splitView.addArrangedSubview(controlsHost)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(800), forSubviewAt: 1)

        context.coordinator.splitView = splitView
        context.coordinator.previewHost = previewHost
        context.coordinator.controlsHost = controlsHost
        splitView.onDidLayoutWithWidth = { [weak coordinator = context.coordinator] in
            coordinator?.applyInitialSizesIfNeeded()
        }
        context.coordinator.applyInitialSizesIfNeeded()
        return splitView
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        context.coordinator.maxLeftRatio = maxLeftRatio
        context.coordinator.initialLeftRatio = initialLeftRatio
        context.coordinator.controlsMinWidth = controlsMinWidth
        context.coordinator.previewHost?.rootView = preview()
        context.coordinator.controlsHost?.rootView = controls()
        context.coordinator.applyInitialSizesIfNeeded()
    }

    final class Coordinator: NSObject, NSSplitViewDelegate {
        var maxLeftRatio: CGFloat
        var initialLeftRatio: CGFloat
        var controlsMinWidth: CGFloat
        weak var splitView: NSSplitView?
        weak var previewHost: NSHostingView<Preview>?
        weak var controlsHost: NSHostingView<Controls>?
        private var initialSizesApplied = false

        init(maxLeftRatio: CGFloat, initialLeftRatio: CGFloat, controlsMinWidth: CGFloat) {
            self.maxLeftRatio = maxLeftRatio
            self.initialLeftRatio = initialLeftRatio
            self.controlsMinWidth = controlsMinWidth
        }

        func applyInitialSizesIfNeeded() {
            guard let splitView, splitView.arrangedSubviews.count >= 2 else { return }
            let total = splitView.bounds.width
            guard total > 1 else { return }
            if !initialSizesApplied {
                initialSizesApplied = true
                let left = min(
                    Int(total * initialLeftRatio),
                    Int(total * maxLeftRatio)
                )
                splitView.setPosition(CGFloat(left), ofDividerAt: 0)
            }
            clampLeftSize()
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            clampLeftSize()
        }

        func splitView(
            _ splitView: NSSplitView,
            additionalEffectiveRectOfDividerAt dividerIndex: Int
        ) -> NSRect {
            let pad: CGFloat = 4
            return NSRect(
                x: -pad,
                y: 0,
                width: pad * 2,
                height: splitView.bounds.height
            )
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMinCoordinate proposedMinimum: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            let total = splitView.bounds.width
            let rightMin = max(1, controlsMinWidth)
            let maxLeft = max(1, min(total * maxLeftRatio, total - rightMin))
            return min(proposedMinimum, maxLeft)
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMaxCoordinate proposedMaximum: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            let total = splitView.bounds.width
            let rightMin = max(1, controlsMinWidth)
            let maxLeft = max(1, min(total * maxLeftRatio, total - rightMin))
            return min(proposedMaximum, maxLeft)
        }

        private func clampLeftSize() {
            guard let splitView, splitView.arrangedSubviews.count >= 2 else { return }
            let total = splitView.bounds.width
            guard total > 0 else { return }
            let rightMin = max(1, controlsMinWidth)
            let maxLeft = max(1, min(total * maxLeftRatio, total - rightMin))
            let currentLeft = splitView.arrangedSubviews[0].frame.width
            if currentLeft <= maxLeft { return }
            splitView.setPosition(maxLeft, ofDividerAt: 0)
        }
    }
}

private final class ImageGenPreviewSplitView: NSSplitView {
    var onDidLayoutWithWidth: (() -> Void)?
    private var lastNotifiedWidth: CGFloat = 0

    override var dividerThickness: CGFloat {
        ImageGenPreviewSplitterMetrics.dividerThickness
    }

    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
        let width = bounds.width
        guard width > 1, abs(width - lastNotifiedWidth) > 0.5 else { return }
        lastNotifiedWidth = width
        onDidLayoutWithWidth?()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isVertical, arrangedSubviews.count >= 2 else { return }
        let leftWidth = arrangedSubviews[0].frame.width
        let thickness = max(dividerThickness, 4)
        let rect = NSRect(
            x: leftWidth - thickness / 2,
            y: 0,
            width: thickness,
            height: bounds.height
        )
        addCursorRect(rect, cursor: .resizeLeftRight)
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isVertical, arrangedSubviews.count >= 2, dividerCursorRect().contains(point) {
            NSCursor.resizeLeftRight.set()
            return
        }
        super.cursorUpdate(with: event)
    }

    private func dividerCursorRect() -> NSRect {
        let leftWidth = arrangedSubviews[0].frame.width
        let thickness = max(dividerThickness, 8)
        return NSRect(
            x: leftWidth - thickness / 2,
            y: 0,
            width: thickness,
            height: bounds.height
        )
    }
}
