import AppKit
import SwiftUI

/// NSSplitView divider metrics (preview | controls).
enum ImageGenPreviewSplitterMetrics {
    /// Visible width of the draggable split divider.
    static let dividerThickness: CGFloat = 15
    /// Hide image preview canvases when the preview pane width is below this (pt).
    static let previewImageHideBelowWidth: CGFloat = 140
    /// Smallest preview column when dragging the split divider (image views have no min size).
    static let previewPaneMinWidth: CGFloat = 0
}

enum ImageGenPreviewSplitterLayout {
    static var controlsPaneMinWidth: CGFloat {
        ImageGenInlineFieldLayout.unifiedSplitControlsPaneMinWidth()
    }

    /// Preview + divider + controls minimum (Python unified shell ``_embedded_panel_minimum_width``).
    static var minimumTotalWidth: CGFloat {
        ImageGenPreviewSplitterMetrics.previewPaneMinWidth
            + ImageGenPreviewSplitterMetrics.dividerThickness
            + controlsPaneMinWidth
    }
}

/// Horizontal preview | controls splitter (Python ``ImageGenPreviewSplitter``).
struct ImageGenPreviewSplitter<Preview: View, Controls: View>: NSViewRepresentable {
    var maxLeftRatio: CGFloat = 0.7
    var initialLeftRatio: CGFloat = 0.5
    var controlsMinWidth: CGFloat = ImageGenPreviewSplitterLayout.controlsPaneMinWidth
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

        let previewClip = ImageGenClippingSplitPaneView()
        let previewHost = ImageGenPreviewPaneHostingView(
            rootView: ImageGenPreviewSplitterPreviewRoot(preview: preview)
        )
        previewClip.embed(previewHost)
        let controlsClip = ImageGenSplitControlsClipPaneView()
        controlsClip.minimumPaneWidth = controlsMinWidth
        let controlsHost = ImageGenPreviewControlsHostingView(
            rootView: ImageGenPreviewSplitterControlsRoot(controls: controls)
        )
        controlsClip.embed(controlsHost)
        previewClip.setContentHuggingPriority(.defaultLow, for: .horizontal)
        controlsClip.setContentHuggingPriority(.defaultLow, for: .horizontal)
        controlsClip.setContentCompressionResistancePriority(.required, for: .horizontal)
        controlsHost.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        splitView.controlsMinWidth = controlsMinWidth
        splitView.addArrangedSubview(previewClip)
        splitView.addArrangedSubview(controlsClip)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(800), forSubviewAt: 1)

        context.coordinator.splitView = splitView
        context.coordinator.previewHost = previewHost
        context.coordinator.controlsClip = controlsClip
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
        context.coordinator.controlsClip?.minimumPaneWidth = controlsMinWidth
        context.coordinator.previewHost?.rootView = ImageGenPreviewSplitterPreviewRoot(preview: preview)
        context.coordinator.controlsHost?.rootView = ImageGenPreviewSplitterControlsRoot(controls: controls)
        if let splitView = context.coordinator.splitView as? ImageGenPreviewSplitView {
            splitView.controlsMinWidth = controlsMinWidth
        }
        context.coordinator.syncPaneHostingLayout()
        context.coordinator.applyInitialSizesIfNeeded()
    }

    final class Coordinator: NSObject, NSSplitViewDelegate {
        var maxLeftRatio: CGFloat
        var initialLeftRatio: CGFloat
        var controlsMinWidth: CGFloat
        weak var splitView: NSSplitView?
        fileprivate weak var previewHost: ImageGenPreviewPaneHostingView<ImageGenPreviewSplitterPreviewRoot<Preview>>?
        fileprivate weak var controlsClip: ImageGenSplitControlsClipPaneView?
        fileprivate weak var controlsHost: ImageGenPreviewControlsHostingView<ImageGenPreviewSplitterControlsRoot<Controls>>?
        private var initialSizesApplied = false

        init(maxLeftRatio: CGFloat, initialLeftRatio: CGFloat, controlsMinWidth: CGFloat) {
            self.maxLeftRatio = maxLeftRatio
            self.initialLeftRatio = initialLeftRatio
            self.controlsMinWidth = controlsMinWidth
        }

        func syncPaneHostingLayout() {
            previewHost?.layoutSubtreeIfNeeded()
            controlsHost?.layoutSubtreeIfNeeded()
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
            syncPaneHostingLayout()
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            clampLeftSize()
            syncPaneHostingLayout()
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
            guard dividerIndex == 0 else { return proposedMinimum }
            return max(proposedMinimum, ImageGenPreviewSplitterMetrics.previewPaneMinWidth)
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMaxCoordinate proposedMaximum: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            guard dividerIndex == 0 else { return proposedMaximum }
            let total = splitView.bounds.width
            let divider = Self.dividerThickness(for: splitView)
            let maxLeft = Self.maxLeftDividerPosition(
                total: total,
                divider: divider,
                controlsMinWidth: controlsMinWidth,
                maxLeftRatio: maxLeftRatio
            )
            return min(proposedMaximum, maxLeft)
        }

        private func clampLeftSize() {
            guard let splitView, splitView.arrangedSubviews.count >= 2 else { return }
            let total = splitView.bounds.width
            guard total > 0 else { return }
            let divider = Self.dividerThickness(for: splitView)
            let maxLeft = Self.maxLeftDividerPosition(
                total: total,
                divider: divider,
                controlsMinWidth: controlsMinWidth,
                maxLeftRatio: maxLeftRatio
            )
            let currentLeft = splitView.arrangedSubviews[0].frame.width
            if currentLeft > maxLeft + 0.5 {
                splitView.setPosition(maxLeft, ofDividerAt: 0)
            }
            let rightWidth = splitView.arrangedSubviews[1].frame.width
            if rightWidth + 0.5 < controlsMinWidth {
                splitView.setPosition(maxLeft, ofDividerAt: 0)
            }
        }

        private static func dividerThickness(for splitView: NSSplitView) -> CGFloat {
            (splitView as? ImageGenPreviewSplitView)?.dividerThickness
                ?? ImageGenPreviewSplitterMetrics.dividerThickness
        }

        private static func maxLeftDividerPosition(
            total: CGFloat,
            divider: CGFloat,
            controlsMinWidth: CGFloat,
            maxLeftRatio: CGFloat
        ) -> CGFloat {
            let rightMin = max(1, controlsMinWidth)
            let widthCap = max(0, total - divider - rightMin)
            let ratioCap = max(0, total * maxLeftRatio)
            return min(ratioCap, widthCap)
        }
    }
}

/// Preview pane fills split slice; image UI hidden when narrower than ``previewImageHideBelowWidth``.
@MainActor
struct ImageGenSplitPreviewPaneColumn<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geo in
            if geo.size.width >= ImageGenPreviewSplitterMetrics.previewImageHideBelowWidth {
                content()
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Options pane flush to the center splitter (Python controls column alignment).
@MainActor
struct ImageGenSplitControlsLeadingColumn<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
    }
}

@MainActor
struct ImageGenPreviewSplitterPreviewRoot<Preview: View>: View {
    @ViewBuilder var preview: () -> Preview

    var body: some View {
        ImageGenSplitPreviewPaneColumn(content: preview)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@MainActor
struct ImageGenPreviewSplitterControlsRoot<Controls: View>: View {
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        ImageGenSplitControlsLeadingColumn(content: controls)
            .environment(\.imageGenControlsInSplitPane, true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Hard clip at split pane bounds so controls never paint into the preview column.
fileprivate class ImageGenClippingSplitPaneView: NSView {
    private weak var embedded: NSView?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func embed(_ view: NSView) {
        embedded?.removeFromSuperview()
        embedded = view
        view.autoresizingMask = [.width, .height]
        view.frame = bounds
        addSubview(view)
    }

    override func layout() {
        super.layout()
        embedded?.frame = NSRect(origin: .zero, size: bounds.size)
    }
}

/// Controls clip pane: reports a horizontal minimum so NSSplitView cannot shrink below content.
fileprivate final class ImageGenSplitControlsClipPaneView: ImageGenClippingSplitPaneView {
    var minimumPaneWidth: CGFloat = ImageGenPreviewSplitterLayout.controlsPaneMinWidth {
        didSet {
            if abs(oldValue - minimumPaneWidth) > 0.5 {
                invalidateIntrinsicContentSize()
            }
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: max(1, minimumPaneWidth), height: NSView.noIntrinsicMetric)
    }
}

/// Controls column: lay out SwiftUI at hosting bounds (leading edge), not intrinsic width.
fileprivate final class ImageGenPreviewControlsHostingView<Content: View>: NSHostingView<Content> {
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        applyLayoutPolicy()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyLayoutPolicy()
    }

    private func applyLayoutPolicy() {
        clipsToBounds = true
        sizingOptions = .standardBounds
    }

    override func layout() {
        super.layout()
        clipsToBounds = true
        layoutSubtreeIfNeeded()
    }
}

/// Preview pane hosting (preview column only).
fileprivate final class ImageGenPreviewPaneHostingView<Content: View>: NSHostingView<Content> {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clipsToBounds = true
    }

    override func layout() {
        super.layout()
        clipsToBounds = true
        layoutSubtreeIfNeeded()
    }
}

private final class ImageGenPreviewSplitView: NSSplitView {
    var onDidLayoutWithWidth: (() -> Void)?
    var controlsMinWidth: CGFloat = ImageGenPreviewSplitterLayout.controlsPaneMinWidth
    private var lastNotifiedWidth: CGFloat = 0

    override var dividerThickness: CGFloat {
        ImageGenPreviewSplitterMetrics.dividerThickness
    }

    override func layout() {
        super.layout()
        enforceControlsPaneMinimumWidth()
        window?.invalidateCursorRects(for: self)
        let width = bounds.width
        guard width > 1, abs(width - lastNotifiedWidth) > 0.5 else { return }
        lastNotifiedWidth = width
        onDidLayoutWithWidth?()
    }

    private func enforceControlsPaneMinimumWidth() {
        guard arrangedSubviews.count >= 2 else { return }
        let divider = dividerThickness
        let total = bounds.width
        guard total > 1 else { return }
        let maxLeft = max(0, total - divider - max(1, controlsMinWidth))
        let leftWidth = arrangedSubviews[0].frame.width
        let rightWidth = arrangedSubviews[1].frame.width
        if rightWidth + 0.5 < controlsMinWidth || leftWidth > maxLeft + 0.5 {
            setPosition(maxLeft, ofDividerAt: 0)
        }
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
