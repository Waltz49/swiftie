import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted after a modal styled message or progress panel dismisses so menu shortcut enablement resyncs.
    static let prowserBrowserShortcutGateShouldRefresh = Notification.Name("prowserBrowserShortcutGateShouldRefresh")
    /// Raise or recreate the primary `Window("Prowser", id: "main")` scene.
    static let prowserShowMainBrowserWindow = Notification.Name("prowser.showMainBrowserWindow")
}

/// Classifies Prowser windows so dialogs can own the key window without leaking
/// browser shortcuts (Python `WindowShortcut` / `present_auxiliary_dialog` parity).
enum BrowserWindowIdentity {
    static let main = "prowser.main"
    static let settings = "prowser.settings"
    static let about = "prowser.about"
    static let dialogPrefix = "prowser.dialog."
    static let styledMessage = "styled-message-dialog"
    /// SwiftUI `Window(..., id:)` values — never treat as the browser main window.
    private static let sceneWindowIDs: Set<String> = ["jobs-panel", "imagegen-unified"]
    private static let sceneWindowTitles: Set<String> = ["Job Control", "Image Generation"]
    private static let mainWindowTitle = "Prowser"

    static func tagMainBrowserWindow(_ window: NSWindow?) {
        guard let window else { return }
        guard !isAuxiliaryWindow(window) else { return }
        window.identifier = NSUserInterfaceItemIdentifier(main)
    }

    /// Primary browser window regardless of visibility (miniaturized, another Space, ordered out).
    static func isTaggedMainBrowserWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        if isAuxiliaryWindow(window) { return false }
        if window.identifier?.rawValue == main { return true }
        return window.title == mainWindowTitle
    }

    /// Visible primary browser (shortcuts / menu gating).
    static func isMainBrowserWindow(_ window: NSWindow?) -> Bool {
        guard let window, window.isVisible else { return false }
        return isTaggedMainBrowserWindow(window)
    }

    /// Best-effort main browser, preferring a visible instance.
    static func resolveMainBrowserWindow() -> NSWindow? {
        let tagged = NSApp.windows.filter(isTaggedMainBrowserWindow)
        if let visible = tagged.first(where: \.isVisible) {
            return visible
        }
        return tagged.first
    }

    /// Deminiaturize, move to the active Space, and key the main browser. Returns false if none exists.
    @discardableResult
    static func bringMainBrowserWindowToFront() -> Bool {
        guard let window = resolveMainBrowserWindow() else { return false }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.collectionBehavior.insert(.moveToActiveSpace)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .prowserBrowserShortcutGateShouldRefresh, object: nil)
        return true
    }

    static func requestShowMainBrowserWindow() {
        if bringMainBrowserWindowToFront() { return }
        NotificationCenter.default.post(name: .prowserShowMainBrowserWindow, object: nil)
    }

    static func isPreferencesWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        if window.identifier?.rawValue == settings { return true }
        return window.title == "Prowser Preferences"
    }

    static func isAuxiliaryWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        if window.isSheet { return true }
        if window is NSPanel { return true }
        if window is AuxiliaryDialogWindow { return true }
        let identifier = window.identifier?.rawValue ?? ""
        if identifier == settings || identifier == about || identifier == styledMessage {
            return true
        }
        if identifier.hasPrefix(dialogPrefix) { return true }
        if sceneWindowIDs.contains(identifier) { return true }
        let title = window.title
        if sceneWindowTitles.contains(title) { return true }
        if title == "Prowser Preferences" { return true }
        if title == "About Prowser" || title == "Credits" || title == "License" { return true }
        return false
    }

    /// True when browser menu shortcuts and `KeyboardHandlerController` may run.
    static func browserWindowOwnsShortcuts(event: NSEvent? = nil) -> Bool {
        if NSApp.modalWindow != nil { return false }
        if let eventWindow = event?.window, isAuxiliaryWindow(eventWindow) {
            return false
        }
        if let key = NSApp.keyWindow {
            if visibleAuxiliaryKeyWindow(key) { return false }
            if isMainBrowserWindow(key) { return true }
        }
        if auxiliaryWindowIsKey() {
            return false
        }
        return NSApp.windows.contains(where: isMainBrowserWindow)
            || NSApp.windows.contains(where: isTaggedMainBrowserWindow)
    }

    /// SwiftUI `CommandMenu` enablement — stays true while the main browser is visible and no
    /// auxiliary dialog is key (menu bar tracking uses a transient non-titled key window).
    static func browserMenuCommandsEnabled() -> Bool {
        if NSApp.modalWindow != nil { return false }
        if auxiliaryWindowIsKey() { return false }
        if NSApp.windows.contains(where: isMainBrowserWindow) {
            return true
        }
        return NSApp.windows.contains(where: isTaggedMainBrowserWindow)
    }

    /// Ordered-out modal panels can remain `isKeyWindow` until the next key change; ignore non-visible windows.
    private static func visibleAuxiliaryKeyWindow(_ window: NSWindow) -> Bool {
        window.isVisible && isAuxiliaryWindow(window)
    }

    private static func auxiliaryWindowIsKey() -> Bool {
        NSApp.windows.contains { $0.isKeyWindow && visibleAuxiliaryKeyWindow($0) }
    }

    /// After `NSApp.runModal(for:)` styled messages, key can stay on an ordered-out panel or become nil;
    /// SwiftUI `CommandMenu` shortcuts (e.g. ⌃⌘P) stay disabled until the main browser is key again.
    static func restoreBrowserKeyAfterAuxiliaryDialog() {
        _ = bringMainBrowserWindowToFront()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .prowserBrowserShortcutGateShouldRefresh, object: nil)
        }
    }

    static func focusFirstTextInput(in window: NSWindow) {
        guard let content = window.contentView else { return }
        if let text = firstTextInput(in: content) {
            window.makeFirstResponder(text)
        }
    }

    private static func firstTextInput(in view: NSView) -> NSView? {
        if view is NSTextView || view is NSTextField || view is NSSecureTextField {
            if let field = view as? NSTextField, !field.isEditable { return nil }
            return view
        }
        for subview in view.subviews {
            if let found = firstTextInput(in: subview) {
                return found
            }
        }
        return nil
    }
}

/// Independent dialog window that can be key (receives keystrokes) without becoming
/// the application main window.
final class AuxiliaryDialogWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Marks the SwiftUI `Window("Prowser")` scene as the browser, never a dialog.
struct MainWindowIdentityAnchor: NSViewRepresentable {
    @Environment(AppState.self) private var appState

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            BrowserWindowIdentity.tagMainBrowserWindow(view.window)
            appState.noteMainBrowserWindowReady()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        BrowserWindowIdentity.tagMainBrowserWindow(nsView.window)
    }
}

/// Recreates the main browser scene when it was closed but auxiliary scenes remain.
struct MainWindowPresentationBridge: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .prowserShowMainBrowserWindow)) { _ in
                if BrowserWindowIdentity.bringMainBrowserWindowToFront() { return }
                openWindow(id: "main")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    BrowserWindowIdentity.bringMainBrowserWindowToFront()
                }
            }
    }
}
