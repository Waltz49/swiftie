import AppKit
import Foundation

/// Brief “✓ Copied!” toast (Python `copy_feedback.py`).
@Observable
@MainActor
final class CopyFeedbackService {
    private(set) var isVisible = false
    private weak var hostWindow: NSWindow?
    private var hideTask: Task<Void, Never>?

    func show(hostWindow: NSWindow? = nil, duration: TimeInterval = 1.5) {
        hideTask?.cancel()
        self.hostWindow = hostWindow ?? NSApp.keyWindow
        isVisible = true
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            isVisible = false
        }
    }

    /// Each ``CopyFeedbackOverlay`` only renders when it lives in the window that initiated the copy.
    func shouldShow(on window: NSWindow?) -> Bool {
        guard isVisible else { return false }
        guard let hostWindow else {
            return BrowserWindowIdentity.isMainBrowserWindow(window)
        }
        return hostWindow === window
    }
}
