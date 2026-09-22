import AppKit
import SwiftUI

/// Closes the hosting auxiliary dialog window (no-op when the view is a nested sheet).
struct DialogCloseAction {
    var close: () -> Void = {}

    func callAsFunction() {
        close()
    }
}

private struct DialogCloseKey: EnvironmentKey {
    static let defaultValue = DialogCloseAction()
}

extension EnvironmentValues {
    var closeDialog: DialogCloseAction {
        get { self[DialogCloseKey.self] }
        set { self[DialogCloseKey.self] = newValue }
    }
}

/// Presents SwiftUI dialogs as independent NSWindows (`present_auxiliary_dialog` parity).
@MainActor
final class AuxiliaryDialogController: NSObject, NSWindowDelegate {
    private struct Session {
        var window: NSWindow
        var onClose: () -> Void
    }

    private var sessions: [String: Session] = [:]

    func isVisible(_ id: String) -> Bool {
        sessions[id]?.window.isVisible == true
    }

    func bringToFront(_ id: String) {
        guard let window = sessions[id]?.window, window.isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func present<Content: View>(
        id: String,
        title: String,
        appState: AppState,
        defaultSize: NSSize,
        minSize: NSSize,
        focusTextOnShow: Bool = false,
        content: Content,
        onClose: @escaping () -> Void
    ) {
        if let existing = sessions[id] {
            if existing.window.isVisible {
                NSApp.activate(ignoringOtherApps: true)
                existing.window.makeKeyAndOrderFront(nil)
                if focusTextOnShow {
                    DispatchQueue.main.async {
                        BrowserWindowIdentity.focusFirstTextInput(in: existing.window)
                    }
                }
                return
            }
            existing.window.delegate = nil
            sessions.removeValue(forKey: id)
            existing.window.close()
        }

        let closeHost: () -> Void = { [weak self] in
            self?.close(id)
        }
        let root = ZStack {
            content
            CopyFeedbackOverlay()
        }
            .environment(appState)
            .environment(\.themeColors, appState.theme.colors)
            .environment(\.closeDialog, DialogCloseAction(close: closeHost))

        let host = NSHostingController(rootView: root)
        let window = AuxiliaryDialogWindow(contentViewController: host)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = minSize
        window.setContentSize(defaultSize)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.identifier = NSUserInterfaceItemIdentifier(BrowserWindowIdentity.dialogPrefix + id)
        window.delegate = self

        sessions[id] = Session(window: window, onClose: onClose)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if focusTextOnShow {
            DispatchQueue.main.async {
                BrowserWindowIdentity.focusFirstTextInput(in: window)
            }
        }
    }

    func close(_ id: String) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        session.window.delegate = nil
        if session.window.isVisible {
            session.window.close()
        }
        session.onClose()
    }

    func closeAll() {
        for id in Array(sessions.keys) {
            close(id)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = sessions.first(where: { $0.value.window === window })?.key
        else { return }
        let session = sessions.removeValue(forKey: id)
        session?.onClose()
    }
}
