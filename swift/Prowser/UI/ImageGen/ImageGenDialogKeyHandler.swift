import AppKit
import SwiftUI

/// Footer keyboard shortcuts from Python `install_image_gen_footer_keyboard_shortcuts`.
struct ImageGenDialogKeyHandler: NSViewRepresentable {
    let onCommandLeft: () -> Void
    let onCommandRight: () -> Void
    let onCommandReturn: () -> Void
    let onCommandW: () -> Void
    let onOptionReturn: () -> Bool
    let onShiftOptionReturn: () -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = KeyCatcherView()
        view.onCommandLeft = onCommandLeft
        view.onCommandRight = onCommandRight
        view.onCommandReturn = onCommandReturn
        view.onCommandW = onCommandW
        view.onOptionReturn = onOptionReturn
        view.onShiftOptionReturn = onShiftOptionReturn
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? KeyCatcherView else { return }
        view.onCommandLeft = onCommandLeft
        view.onCommandRight = onCommandRight
        view.onCommandReturn = onCommandReturn
        view.onCommandW = onCommandW
        view.onOptionReturn = onOptionReturn
        view.onShiftOptionReturn = onShiftOptionReturn
    }

    final class KeyCatcherView: NSView {
        var onCommandLeft: (() -> Void)?
        var onCommandRight: (() -> Void)?
        var onCommandReturn: (() -> Void)?
        var onCommandW: (() -> Void)?
        var onOptionReturn: (() -> Bool)?
        var onShiftOptionReturn: (() -> Bool)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command, event.charactersIgnoringModifiers == "w" {
                onCommandW?()
                return
            }
            if flags == [.command, .option, .shift],
               event.keyCode == 36 || event.keyCode == 76 {
                if onShiftOptionReturn?() == true { return }
            }
            if flags == .option, event.keyCode == 36 || event.keyCode == 76 {
                if onOptionReturn?() == true { return }
            }
            if flags == .command {
                if event.keyCode == 123 {
                    onCommandLeft?()
                    return
                }
                if event.keyCode == 124 {
                    onCommandRight?()
                    return
                }
                if event.keyCode == 36 || event.keyCode == 76 {
                    onCommandReturn?()
                    return
                }
            }
            super.keyDown(with: event)
        }
    }
}
