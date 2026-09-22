import AppKit
import SwiftUI

/// One button in a dialog's bottom row (Qt `QDialogButtonBox` parity).
struct DialogButton: Identifiable {
    let id: String
    var title: String
    /// Activated by Return when no row button has keyboard focus (Qt default button).
    var isDefault = false
    /// Activated by Esc (Qt `reject`).
    var isCancel = false
    var isEnabled = true
    var help: String?
    var action: () -> Void

    init(
        _ title: String,
        id: String? = nil,
        isDefault: Bool = false,
        isCancel: Bool = false,
        isEnabled: Bool = true,
        help: String? = nil,
        action: @escaping () -> Void
    ) {
        self.id = id ?? title
        self.title = title
        self.isDefault = isDefault
        self.isCancel = isCancel
        self.isEnabled = isEnabled
        self.help = help
        self.action = action
    }
}

enum DialogButtonRowLayout {
    /// Leading controls on the left, trailing buttons on the right (default sheet footer).
    case standard
    /// Buttons only — embed in a parent `HStack` (e.g. image-gen dialog footer).
    case inline
}

/// Right-aligned dialog button row with Qt-style keyboard behaviour:
/// buttons are focusable (Tab sequence), ←/→ move between them, Return/Space activate the
/// focused button (Return falls back to the default button), Esc activates the cancel button.
/// `leading` content (extra controls) is placed on the left of the row.
struct DialogButtonRow<Leading: View>: View {
    /// Right-aligned buttons.
    let buttons: [DialogButton]
    /// Left-aligned buttons (still part of the keyboard cycle).
    let leadingButtons: [DialogButton]
    /// Focus the default (or first) button when the dialog appears.
    var focusDefaultOnAppear = false
    /// When false, Return does not activate the default button unless a footer button already has SwiftUI focus.
    var allowReturnActivatesDefault = true
    /// When false, the default button does not register SwiftUI `.defaultAction` (avoids accidental OK with content buttons).
    var useSwiftUIDefaultActionShortcut = true
    var layout: DialogButtonRowLayout = .standard
    @ViewBuilder var leading: () -> Leading

    @Environment(\.themeColors) private var colors
    @FocusState private var focusedID: String?

    init(
        _ buttons: [DialogButton],
        leadingButtons: [DialogButton] = [],
        focusDefaultOnAppear: Bool = false,
        allowReturnActivatesDefault: Bool = true,
        useSwiftUIDefaultActionShortcut: Bool = true,
        layout: DialogButtonRowLayout = .standard,
        @ViewBuilder leading: @escaping () -> Leading = { EmptyView() }
    ) {
        self.buttons = buttons
        self.leadingButtons = leadingButtons
        self.focusDefaultOnAppear = focusDefaultOnAppear
        self.allowReturnActivatesDefault = allowReturnActivatesDefault
        self.useSwiftUIDefaultActionShortcut = useSwiftUIDefaultActionShortcut
        self.layout = layout
        self.leading = leading
    }

    var body: some View {
        Group {
            switch layout {
            case .standard:
                HStack(spacing: 8) {
                    ForEach(leadingButtons) { rowButton($0) }
                    leading()
                    Spacer()
                    ForEach(buttons) { rowButton($0) }
                }
            case .inline:
                HStack(spacing: 8) {
                    ForEach(leadingButtons) { rowButton($0) }
                    leading()
                    ForEach(buttons) { rowButton($0) }
                }
            }
        }
        .background(
            DialogKeyRoutingView(handler: handle(_:))
                .frame(width: 0, height: 0)
        )
        .onAppear {
            guard focusDefaultOnAppear else { return }
            DispatchQueue.main.async { focusedID = initialButtonID }
        }
    }

    private func rowButton(_ button: DialogButton) -> some View {
        Button(button.title) {
            button.action()
        }
        .keyboardShortcut(button.isDefault && useSwiftUIDefaultActionShortcut ? .defaultAction : nil)
        .disabled(!button.isEnabled)
        .focusable(button.isEnabled)
        .focused($focusedID, equals: button.id)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(focusedID == button.id ? colors.currentImageBorder : .clear, lineWidth: 1.5)
                .padding(-2)
        )
        .help(button.help ?? "")
    }

    /// Keyboard cycle order (left to right).
    private var enabledButtons: [DialogButton] { (leadingButtons + buttons).filter(\.isEnabled) }

    private var initialButtonID: String? {
        (enabledButtons.first(where: \.isDefault) ?? enabledButtons.first)?.id
    }

    /// Returns `true` when the key event was consumed.
    @MainActor
    private func handle(_ event: NSEvent) -> Bool {
        let textFocused = (event.window?.firstResponder).map(KeyboardHandlerController.isTextEditingResponder) ?? false
        if let responder = event.window?.firstResponder, Self.isAdjustableControlResponder(responder) {
            focusedID = nil
        }
        switch event.keyCode {
        case 53: // Esc
            guard let cancel = enabledButtons.first(where: \.isCancel) else { return false }
            cancel.action()
            return true
        case 123, 124: // ← →
            guard !textFocused else { return false }
            if let responder = event.window?.firstResponder, Self.isAdjustableControlResponder(responder) {
                return false
            }
            let enabled = enabledButtons
            guard !enabled.isEmpty else { return false }
            guard let current = focusedID, let index = enabled.firstIndex(where: { $0.id == current }) else {
                return false
            }
            let step = event.keyCode == 124 ? 1 : -1
            focusedID = enabled[(index + step + enabled.count) % enabled.count].id
            return true
        case 36, 76, 49: // Return, Enter, Space
            // Text input focused: leave Return to SwiftUI (`.defaultAction` shortcut) so field
            // values commit first, and multi-line editors keep newlines.
            guard !textFocused else { return false }
            if let responder = event.window?.firstResponder, Self.isAdjustableControlResponder(responder) {
                return false
            }
            if let current = focusedID, let button = enabledButtons.first(where: { $0.id == current }) {
                button.action()
                return true
            }
            if event.keyCode != 49,
               allowReturnActivatesDefault,
               let def = enabledButtons.first(where: \.isDefault),
               Self.shouldReturnActivateDefaultButton(event: event) {
                def.action()
                return true
            }
            return false
        default:
            return false
        }
    }

    /// Return activates the default footer button only when no other control should consume it.
    @MainActor
    private static func shouldReturnActivateDefaultButton(event: NSEvent) -> Bool {
        if NSApp.modalWindow != nil { return false }
        guard let responder = event.window?.firstResponder else { return true }
        if responder is NSButton { return false }
        if isAdjustableControlResponder(responder) { return false }
        if KeyboardHandlerController.isTextEditingResponder(responder) { return false }
        return true
    }

    /// Sliders, steppers, pickers, etc. — arrow keys adjust values, not footer button focus.
    private static func isAdjustableControlResponder(_ responder: NSResponder) -> Bool {
        if responder is NSSlider || responder is NSStepper || responder is NSPopUpButton {
            return true
        }
        let typeName = String(describing: type(of: responder))
        if typeName.contains("Slider") || typeName.contains("Stepper") { return true }
        if typeName.contains("Picker") || typeName.contains("PopUpButton") || typeName.contains("ComboBox") {
            return true
        }
        if typeName.contains("Toggle") || typeName.contains("Switch") { return true }
        if let view = responder as? NSView {
            var current: NSView? = view
            while let candidate = current {
                if candidate is NSSlider || candidate is NSStepper || candidate is NSPopUpButton {
                    return true
                }
                let name = String(describing: type(of: candidate))
                if name.contains("Slider") || name.contains("Stepper") || name.contains("Picker") {
                    return true
                }
                current = candidate.superview
            }
        }
        return false
    }
}

/// Local key monitor scoped to the window that hosts the dialog.
private struct DialogKeyRoutingView: NSViewRepresentable {
    let handler: @MainActor (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.host = view
        context.coordinator.handler = handler
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handler = handler
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        weak var host: NSView?
        var handler: (@MainActor (NSEvent) -> Bool)?
        private var monitor: Any?

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.host?.window, event.window === window, window.isKeyWindow else {
                    return event
                }
                // Let ⌘-shortcuts (e.g. ⌘↩) through untouched.
                if event.modifierFlags.contains(.command) { return event }
                let consumed = MainActor.assumeIsolated { self.handler?(event) ?? false }
                return consumed ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
