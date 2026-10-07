import AppKit
import SwiftUI

/// Footer keyboard shortcuts from Python `install_image_gen_footer_keyboard_shortcuts`
/// (event filter on all dialog widgets — works while a text field is first responder).
struct ImageGenDialogKeyHandler: NSViewRepresentable {
    let windowIdentifier: String
    let onCommandLeft: () -> Void
    let onCommandRight: () -> Void
    let onCommandReturn: () -> Void
    let onCommandW: () -> Void
    let onEscape: () -> Void
    let onOptionReturn: () -> Bool
    let onShiftOptionReturn: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.attach(to: view, settings: self)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.attach(to: nsView, settings: self)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        private var monitor: Any?
        private weak var window: NSWindow?
        private var windowIdentifier: String?
        private var onCommandLeft: (() -> Void)?
        private var onCommandRight: (() -> Void)?
        private var onCommandReturn: (() -> Void)?
        private var onCommandW: (() -> Void)?
        private var onEscape: (() -> Void)?
        private var onOptionReturn: (() -> Bool)?
        private var onShiftOptionReturn: (() -> Bool)?

        func attach(to view: NSView, settings: ImageGenDialogKeyHandler) {
            guard let hostWindow = view.window else { return }
            if window === hostWindow,
               windowIdentifier == settings.windowIdentifier,
               monitor != nil {
                onCommandLeft = settings.onCommandLeft
                onCommandRight = settings.onCommandRight
                onCommandReturn = settings.onCommandReturn
                onCommandW = settings.onCommandW
                onEscape = settings.onEscape
                onOptionReturn = settings.onOptionReturn
                onShiftOptionReturn = settings.onShiftOptionReturn
                return
            }
            detach()
            window = hostWindow
            windowIdentifier = settings.windowIdentifier
            onCommandLeft = settings.onCommandLeft
            onCommandRight = settings.onCommandRight
            onCommandReturn = settings.onCommandReturn
            onCommandW = settings.onCommandW
            onEscape = settings.onEscape
            onOptionReturn = settings.onOptionReturn
            onShiftOptionReturn = settings.onShiftOptionReturn

            let expectedID = settings.windowIdentifier
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                guard self.matchesHostWindow(event: event, expectedIdentifier: expectedID) else { return event }

                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

                if event.keyCode == 53 {
                    self.onEscape?()
                    return nil
                }

                if flags == .command, event.charactersIgnoringModifiers == "w" {
                    self.onCommandW?()
                    return nil
                }

                if event.keyCode == 36 || event.keyCode == 76 {
                    let modsNoKeypad = flags.subtracting(.numericPad)
                    if modsNoKeypad == [.command, .option, .shift] {
                        if self.onShiftOptionReturn?() == true { return nil }
                    }
                    if modsNoKeypad == .option {
                        if self.onOptionReturn?() == true { return nil }
                    }
                    if flags == .command {
                        self.onCommandReturn?()
                        return nil
                    }
                }

                if flags == .command {
                    if event.keyCode == 123 {
                        self.onCommandLeft?()
                        return nil
                    }
                    if event.keyCode == 124 {
                        self.onCommandRight?()
                        return nil
                    }
                }
                return event
            }
        }

        func detach() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
            window = nil
            windowIdentifier = nil
        }

        private func matchesHostWindow(event: NSEvent, expectedIdentifier: String) -> Bool {
            guard let window else { return false }
            if window.identifier?.rawValue != expectedIdentifier { return false }
            if event.window === window { return true }
            if window.isKeyWindow { return true }
            return NSApp.keyWindow === window
        }
    }
}
