import AppKit

/// App-level mouse tracking for hidden status bar peek (Python `StatusBarPeekFilter`).
@MainActor
final class StatusBarPeekMonitor {
    private weak var appState: AppState?
    private var monitor: Any?
    private let peekZoneHeight: CGFloat = 35

    func bind(_ appState: AppState) {
        self.appState = appState
        installMonitor()
    }

    func uninstall() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleMouseMoved(event)
            return event
        }
    }

    private func handleMouseMoved(_ event: NSEvent) {
        guard let appState, event.window != nil else { return }
        let nearBottom = event.locationInWindow.y <= peekZoneHeight
        appState.updateStatusBarPeek(nearBottom: nearBottom)
    }
}
