import AppKit
import SwiftUI

/// Drags the host window (Python frameless floating job panel header).
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragView {
        WindowDragView()
    }

    func updateNSView(_ nsView: WindowDragView, context: Context) {}
}

final class WindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 30)
    }
}
