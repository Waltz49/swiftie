import AppKit
import SwiftUI

/// SwiftUI `Window` scenes for imagegen (jobs panel, unified dialog).
@MainActor
enum SceneWindowChrome {
    nonisolated static let jobsPanelID = "jobs-panel"
    nonisolated static let imageGenUnifiedID = "imagegen-unified"

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

    static func bringImageGenUnifiedWindowToFront() -> Bool {
        guard let window = imageGenUnifiedWindow() else { return false }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return true
    }
}

/// Coalesces duplicate ``openWindow`` requests (main + floating jobs bridges, stale re-present).
@MainActor
enum ImageGenUnifiedWindowPresentation {
    private static var pendingWork: DispatchWorkItem?

    static func schedulePresent(openWindow: @escaping () -> Void) {
        pendingWork?.cancel()
        let work = DispatchWorkItem {
            if SceneWindowChrome.bringImageGenUnifiedWindowToFront() {
                NotificationCenter.default.post(name: .prowserRaiseImageGenDialog, object: nil)
                return
            }
            openWindow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if SceneWindowChrome.bringImageGenUnifiedWindowToFront() {
                    NotificationCenter.default.post(name: .prowserRaiseImageGenDialog, object: nil)
                }
            }
        }
        pendingWork = work
        DispatchQueue.main.async(execute: work)
    }
}

/// Calls ``openWindow(id: "imagegen-unified")`` when the unified scene is missing (e.g. job-card edit while flag already true).
struct ImageGenUnifiedWindowPresentationBridge: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onReceive(NotificationCenter.default.publisher(for: .prowserPresentImageGenUnifiedWindow)) { _ in
                appState.showImageGenUnifiedDialog = true
                ImageGenUnifiedWindowPresentation.schedulePresent {
                    openWindow(id: SceneWindowChrome.imageGenUnifiedID)
                }
            }
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
