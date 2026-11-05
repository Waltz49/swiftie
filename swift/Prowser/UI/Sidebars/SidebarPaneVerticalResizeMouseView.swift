import AppKit
import SwiftUI

/// Flipped overlay for stable vertical resize coordinates in a sidebar column.
@MainActor
final class SidebarPaneResizeCoordinateNSView: NSView {
    override var isFlipped: Bool { true }
}

/// AppKit mouse handler for pane titlebar / splitter resize (Python ``HeaderWidget`` drag).
@MainActor
final class SidebarPaneVerticalResizeMouseNSView: NSView {
    var paneIndex: Int = 0
    var splitModel: SidebarPaneSplitModel?
    var appState: AppState?
    var dragThreshold: CGFloat = 3
    var onDragStarted: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    private var pressWindowY: CGFloat?
    private var dragging = false
    /// Local monitor (Python ``HeaderWidget.grabMouse``) so drag continues outside the titlebar.
    private var dragEventMonitor: Any?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard splitModel != nil, appState != nil else { return }
        pressWindowY = splitModel?.resizeCoordinateY(for: event, fallbackView: self)
        dragging = false
        installDragEventMonitorIfNeeded()
    }

    override func mouseDragged(with event: NSEvent) {
        _ = processPaneResizeDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        finishPaneResizeMouseUp(with: event)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            cancelPaneResizeTracking(endSplitDrag: dragging)
        }
    }

    deinit {
        if let dragEventMonitor {
            NSEvent.removeMonitor(dragEventMonitor)
        }
    }

    private func installDragEventMonitorIfNeeded() {
        guard dragEventMonitor == nil else { return }
        dragEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) {
            [weak self] event in
            guard let self else { return event }
            return self.handleMonitoredMouseEvent(event)
        }
    }

    private func removeDragEventMonitor() {
        guard let dragEventMonitor else { return }
        NSEvent.removeMonitor(dragEventMonitor)
        self.dragEventMonitor = nil
    }

    private func handleMonitoredMouseEvent(_ event: NSEvent) -> NSEvent? {
        guard pressWindowY != nil || dragging else {
            if event.type == .leftMouseUp {
                removeDragEventMonitor()
            }
            return event
        }
        switch event.type {
        case .leftMouseDragged:
            _ = processPaneResizeDrag(with: event)
            return nil
        case .leftMouseUp:
            finishPaneResizeMouseUp(with: event)
            return nil
        default:
            return event
        }
    }

    @discardableResult
    private func processPaneResizeDrag(with event: NSEvent) -> Bool {
        guard let splitModel, let appState else { return false }
        let currentY = splitModel.resizeCoordinateY(for: event, fallbackView: nil)
            ?? splitModel.resizeCoordinateY(for: event, fallbackView: self)
        guard let pressY = pressWindowY ?? currentY, let currentY else {
            return false
        }
        if !dragging {
            guard abs(currentY - pressY) >= dragThreshold else { return true }
            dragging = true
            onDragStarted?()
            splitModel.beginPaneResizeDrag(paneIndex: paneIndex, pressWindowY: pressY, appState: appState)
        }
        splitModel.applyPaneResizeDrag(paneIndex: paneIndex, currentWindowY: currentY, appState: appState)
        return true
    }

    private func finishPaneResizeMouseUp(with event: NSEvent) {
        let wasDragging = dragging
        defer {
            removeDragEventMonitor()
            pressWindowY = nil
            dragging = false
        }
        if wasDragging, let splitModel, let appState {
            splitModel.endPaneResizeDrag(appState: appState, paneIndex: paneIndex)
            return
        }
        if event.clickCount >= 2 {
            onDoubleClick?()
        }
    }

    private func cancelPaneResizeTracking(endSplitDrag: Bool) {
        if endSplitDrag, let splitModel, let appState {
            splitModel.endPaneResizeDrag(appState: appState, paneIndex: paneIndex)
        }
        removeDragEventMonitor()
        pressWindowY = nil
        dragging = false
    }
}

struct SidebarPaneVerticalResizeMouseView: NSViewRepresentable {
    let paneIndex: Int
    let splitModel: SidebarPaneSplitModel
    let appState: AppState
    var onDragStarted: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    func makeNSView(context: Context) -> SidebarPaneVerticalResizeMouseNSView {
        SidebarPaneVerticalResizeMouseNSView(frame: .zero)
    }

    func updateNSView(_ nsView: SidebarPaneVerticalResizeMouseNSView, context: Context) {
        nsView.paneIndex = paneIndex
        nsView.splitModel = splitModel
        nsView.appState = appState
        nsView.onDragStarted = onDragStarted
        nsView.onDoubleClick = onDoubleClick
    }
}

/// Registers the stacked sidebar column for resize coordinate conversion.
struct SidebarPaneResizeCoordinateAnchor: NSViewRepresentable {
    let splitModel: SidebarPaneSplitModel

    func makeNSView(context: Context) -> SidebarPaneResizeCoordinateNSView {
        let view = SidebarPaneResizeCoordinateNSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }

    func updateNSView(_ nsView: SidebarPaneResizeCoordinateNSView, context: Context) {
        splitModel.resizeCoordinateReferenceView = nsView
    }

    static func dismantleNSView(_ nsView: SidebarPaneResizeCoordinateNSView, coordinator: ()) {
        _ = nsView
    }
}
