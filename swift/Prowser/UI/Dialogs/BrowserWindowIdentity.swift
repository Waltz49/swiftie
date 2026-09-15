import AppKit
import SwiftUI

/// Classifies Prowser windows so dialogs can own the key window without leaking
/// browser shortcuts (Python `WindowShortcut` / `present_auxiliary_dialog` parity).
enum BrowserWindowIdentity {
    static let main = "prowser.main"
    static let settings = "prowser.settings"
    static let about = "prowser.about"
    static let dialogPrefix = "prowser.dialog."
    static let styledMessage = "styled-message-dialog"

    static func tagMainBrowserWindow(_ window: NSWindow?) {
        guard let window else { return }
        guard !isAuxiliaryWindow(window) else { return }
        window.identifier = NSUserInterfaceItemIdentifier(main)
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
        let title = window.title
        if title == "Prowser Preferences" { return true }
        if title == "About Prowser" || title == "Credits" || title == "License" { return true }
        return false
    }

    static func isMainBrowserWindow(_ window: NSWindow?) -> Bool {
        guard let window, window.isVisible else { return false }
        if isAuxiliaryWindow(window) { return false }
        if window.identifier?.rawValue == main { return true }
        return window.canBecomeKey && window.styleMask.contains(.titled)
    }

    /// True when browser menu shortcuts and `KeyboardHandlerController` may run.
    static func browserWindowOwnsShortcuts(event: NSEvent? = nil) -> Bool {
        if NSApp.modalWindow != nil { return false }
        if let eventWindow = event?.window, isAuxiliaryWindow(eventWindow) {
            return false
        }
        guard let key = NSApp.keyWindow else { return false }
        return isMainBrowserWindow(key)
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
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            BrowserWindowIdentity.tagMainBrowserWindow(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        BrowserWindowIdentity.tagMainBrowserWindow(nsView.window)
    }
}
