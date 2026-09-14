import AppKit

/// Scrolls the preferences detail `ScrollView` so the keyboard-focused control stays visible (Tab / Shift-Tab).
@MainActor
enum SettingsScrollFocus {
    static func scrollFirstResponderIntoView(in window: NSWindow) {
        guard KeyboardHandlerController.isPreferencesWindow(window) else { return }
        guard let target = viewToReveal(for: window.firstResponder) else { return }
        guard let scrollView = target.enclosingScrollView else { return }
        // Footer buttons sit outside the tab `ScrollView`; only scroll within the detail column.
        guard scrollViewIsInSettingsDetail(scrollView, window: window) else { return }

        let clip = scrollView.contentView
        var rect = target.convert(target.bounds, to: clip)
        rect = rect.insetBy(dx: -12, dy: -16)
        clip.scrollToVisible(rect)
    }

    private static func scrollViewIsInSettingsDetail(_ scrollView: NSScrollView, window: NSWindow) -> Bool {
        guard let content = window.contentView else { return false }
        var view: NSView? = scrollView
        while let current = view {
            if current === content { return true }
            view = current.superview
        }
        return false
    }

    private static func viewToReveal(for responder: NSResponder?) -> NSView? {
        guard let responder else { return nil }
        if let view = responder as? NSView {
            return meaningfulFocusView(view)
        }
        if let textView = responder as? NSTextView {
            if textView.isFieldEditor {
                if let field = textView.delegate as? NSView {
                    return meaningfulFocusView(field)
                }
            }
            return meaningfulFocusView(textView)
        }
        return nil
    }

    /// Prefer the control chrome over internal SwiftUI/AppKit subviews when walking up.
    private static func meaningfulFocusView(_ view: NSView) -> NSView {
        var candidate: NSView = view
        var current: NSView? = view
        while let walk = current {
            if walk is NSControl || walk is NSButton {
                candidate = walk
            }
            let name = String(describing: type(of: walk))
            if name.contains("Slider") || name.contains("Stepper") || name.contains("Picker") {
                candidate = walk
            }
            current = walk.superview
        }
        return candidate
    }
}
