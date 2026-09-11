import AppKit

/// Dialog button that is always part of the Tab sequence / focusable (Qt `QPushButton` parity),
/// independent of the system "Full Keyboard Access" setting.
final class FocusableDialogButton: NSButton {
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled && !isHidden }
}

/// Qt-style ←/→, Tab, Return, and Esc handling for AppKit dialog button rows.
@MainActor
enum AppKitDialogKeyboardNavigation {
    static func install(
        on window: NSWindow,
        buttonsLeftToRight: [NSButton],
        escapeButton: NSButton?,
        hasTextAccessory: Bool = false
    ) -> Any? {
        guard escapeButton != nil || !buttonsLeftToRight.isEmpty else { return nil }

        return NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Floating panels share the parent key window; during `runModal(for:)` route keys
            // to the modal panel even when `event.window` is still the main window.
            let isModalDialog = NSApp.modalWindow === window
            guard isModalDialog || (window.isKeyWindow && event.window === window) else { return event }

            if event.keyCode == 53, let escapeButton {
                escapeButton.performClick(nil)
                return nil
            }

            let focused = window.firstResponder as? NSButton
            let currentIndex = focused.flatMap { buttonsLeftToRight.firstIndex(of: $0) }

            if event.keyCode == 36 || event.keyCode == 76, let currentIndex {
                buttonsLeftToRight[currentIndex].performClick(nil)
                return nil
            }

            guard buttonsLeftToRight.count >= 2 else { return event }

            if let responder = window.firstResponder, KeyboardHandlerController.isTextEditingResponder(responder) {
                return event
            }

            let direction: Int?
            switch event.keyCode {
            case 123: direction = -1
            case 124: direction = 1
            case 48 where !hasTextAccessory: direction = event.modifierFlags.contains(.shift) ? -1 : 1
            default: direction = nil
            }
            guard let direction else { return event }

            let nextIndex: Int
            if let currentIndex {
                nextIndex = (currentIndex + direction + buttonsLeftToRight.count) % buttonsLeftToRight.count
            } else {
                nextIndex = direction > 0 ? 0 : buttonsLeftToRight.count - 1
            }
            window.makeFirstResponder(buttonsLeftToRight[nextIndex])
            return nil
        }
    }
}
