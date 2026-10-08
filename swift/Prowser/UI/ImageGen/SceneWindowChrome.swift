import AppKit
import SwiftUI

/// SwiftUI `Window` scenes for imagegen (jobs panel, unified dialog).
@MainActor
enum SceneWindowChrome {
    static let jobsPanelID = "jobs-panel"
    static let imageGenUnifiedID = "imagegen-unified"

    static func window(identifier: String, title: String? = nil) -> NSWindow? {
        NSApp.windows.first { window in
            if window.identifier?.rawValue == identifier { return true }
            if let title, window.title == title { return true }
            return false
        }
    }

    static func jobsPanelWindow() -> NSWindow? {
        window(identifier: jobsPanelID, title: "Job Control")
    }

    static func imageGenUnifiedWindow() -> NSWindow? {
        window(identifier: imageGenUnifiedID, title: "Image Generation")
    }

    static func applyJobsPanelAlwaysOnTop(_ enabled: Bool) {
        guard let window = jobsPanelWindow() else { return }
        window.level = enabled ? .floating : .normal
        if enabled {
            window.collectionBehavior.insert(.fullScreenAuxiliary)
        }
    }

    static func isJobsPanelWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        if window.identifier?.rawValue == jobsPanelID { return true }
        return window.title == "Job Control"
    }
}

/// Sync AppState when the user closes a SwiftUI scene window (red button, ⌘W), not on transient view teardown.
struct SceneWindowLifecycleBridge: NSViewRepresentable {
    let windowIdentifier: String
    let onWillClose: () -> Void

    @MainActor
    func makeCoordinator() -> Coordinator {
        Coordinator(onWillClose: onWillClose)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.attach(to: view, windowIdentifier: windowIdentifier)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.attach(to: nsView, windowIdentifier: windowIdentifier)
        }
    }

    @MainActor
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        private let onWillClose: () -> Void
        private weak var observedWindow: NSWindow?
        private var closeObserver: NSObjectProtocol?

        init(onWillClose: @escaping () -> Void) {
            self.onWillClose = onWillClose
        }

        func attach(to view: NSView, windowIdentifier: String) {
            guard let window = view.window else { return }
            guard window.identifier?.rawValue == windowIdentifier else { return }
            if observedWindow === window, closeObserver != nil { return }
            detach()
            observedWindow = window
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onWillClose()
                }
            }
        }

        func detach() {
            if let closeObserver {
                NotificationCenter.default.removeObserver(closeObserver)
            }
            closeObserver = nil
            observedWindow = nil
        }
    }
}
