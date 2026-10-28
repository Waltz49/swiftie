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
    }

    override func mouseDragged(with event: NSEvent) {
        guard let splitModel, let appState else { return }
        let currentY = splitModel.resizeCoordinateY(for: event, fallbackView: self)
        guard let pressY = pressWindowY ?? currentY, let currentY else { return }
        if !dragging {
            guard abs(currentY - pressY) >= dragThreshold else { return }
            dragging = true
            onDragStarted?()
            splitModel.beginPaneResizeDrag(paneIndex: paneIndex, pressWindowY: pressY, appState: appState)
        }
        splitModel.applyPaneResizeDrag(paneIndex: paneIndex, currentWindowY: currentY, appState: appState)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressWindowY = nil
            dragging = false
        }
        if dragging, let splitModel, let appState {
            splitModel.endPaneResizeDrag(appState: appState, paneIndex: paneIndex)
            return
        }
        if event.clickCount >= 2 {
            onDoubleClick?()
        }
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
