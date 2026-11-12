import AppKit
import Foundation

extension Notification.Name {
    /// Posted when ``CopyFeedbackService/isVisible`` changes so overlays refresh reliably.
    static let prowserCopyFeedbackVisibilityDidChange = Notification.Name("prowser.copyFeedbackVisibilityDidChange")
}

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
        notifyVisibilityDidChange()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            isVisible = false
            notifyVisibilityDidChange()
        }
    }

    private func notifyVisibilityDidChange() {
        NotificationCenter.default.post(name: .prowserCopyFeedbackVisibilityDidChange, object: nil)
    }

    /// Each ``CopyFeedbackOverlay`` only renders when it lives in the window that initiated the copy.
    func shouldShow(on window: NSWindow?) -> Bool {
        guard isVisible else { return false }
        guard let window else {
            return false
        }
        guard let hostWindow else {
            let ok = BrowserWindowIdentity.isMainBrowserWindow(window)
            return ok
        }
        if hostWindow === window {
            return true
        }
        if let hostID = hostWindow.identifier?.rawValue,
           let windowID = window.identifier?.rawValue,
           !hostID.isEmpty,
           hostID == windowID {
            return true
        }
        if BrowserWindowIdentity.isTaggedMainBrowserWindow(hostWindow),
           BrowserWindowIdentity.isTaggedMainBrowserWindow(window) {
            return true
        }
        if hostWindow.title == window.title, !hostWindow.title.isEmpty {
            return true
        }
        return false
    }
}
