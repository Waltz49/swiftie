import AppKit

/// Common message and confirmation dialogs — port of Python ``styled_message_box`` /
/// ``show_styled_*`` in ``utils.py``.
@MainActor
enum StyledMessageDialog {
    enum ButtonRole: Sendable {
        /// Cancel, Close, No, Abort — aligned to the leading edge (Python left group).
        case dismissive
        /// OK, Yes, Delete, Apply — aligned to the trailing edge (Python right group).
        case affirmative
    }

    enum IconKind: Sendable {
        case none
        case warning
        case critical
        case information
        case question
    }

    struct Button: Sendable {
        let title: String
        let role: ButtonRole

        init(_ title: String, role: ButtonRole = .affirmative) {
            self.title = title
            self.role = role
        }
    }

    /// Button index in visual left-to-right order, or ``nil`` when dismissed.
    @discardableResult
    static func present(
        title: String,
        message: String,
        secondaryMessage: String? = nil,
        style: NSAlert.Style = .informational,
        icon: IconKind? = nil,
        buttons: [Button] = [Button("OK")],
        defaultButtonIndex: Int? = nil,
        escapeButtonIndex: Int? = nil,
        accessoryView: NSView? = nil,
        initialFirstResponder: NSView? = nil,
        parentWindow: NSWindow? = nil
    ) -> Int? {
        let specs = buttons.isEmpty ? [Button("OK")] : buttons
        let leftToRight = visualLeftToRightOrder(specs)
        let defaultVisualIndex = defaultButtonIndex ?? defaultVisualIndexForButtons(specs)
        let escapeVisualIndex = escapeButtonIndex ?? escapeVisualIndexForButtons(specs)
        let iconKind = icon ?? iconKind(for: style)

        let controller = StyledMessagePanelController(
            title: title,
            message: message,
            secondaryMessage: secondaryMessage,
            icon: iconKind,
            buttons: leftToRight,
            defaultButtonIndex: defaultVisualIndex,
            escapeButtonIndex: escapeVisualIndex,
            accessoryView: accessoryView,
            initialFirstResponder: initialFirstResponder
        )

        let monitor = AppKitDialogKeyboardNavigation.install(
            on: controller.panel,
            buttonsLeftToRight: controller.buttonsLeftToRight,
            escapeButton: controller.escapeButton,
            hasTextAccessory: accessoryView != nil
        )
        defer {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        controller.runModal(parentWindow: parentWindow)
        return controller.selectedIndex
    }

    static func showWarning(title: String, message: String) {
        present(title: title, message: message, style: .warning, icon: .warning)
    }

    static func showInformation(title: String, message: String) {
        present(title: title, message: message, style: .informational, icon: .information)
    }

    static func showCritical(title: String, message: String) {
        present(title: title, message: message, style: .critical, icon: .critical)
    }

    @discardableResult
    static func showQuestion(
        title: String,
        message: String,
        defaultNo: Bool = true
    ) -> Bool {
        let defaultIndex = defaultNo ? 0 : 1
        let index = present(
            title: title,
            message: message,
            style: .warning,
            icon: .question,
            buttons: [Button("No", role: .dismissive), Button("Yes")],
            defaultButtonIndex: defaultIndex,
            escapeButtonIndex: 0
        )
        return index == 1
    }

    @discardableResult
    static func showOkCancel(
        title: String,
        message: String,
        defaultCancel: Bool = true
    ) -> Bool {
        let defaultIndex = defaultCancel ? 0 : 1
        let index = present(
            title: title,
            message: message,
            style: .informational,
            icon: .question,
            buttons: [Button("Cancel", role: .dismissive), Button("OK")],
            defaultButtonIndex: defaultIndex,
            escapeButtonIndex: 0
        )
        return index == 1
    }

    @discardableResult
    static func showConfirm(
        title: String,
        message: String,
        secondaryMessage: String? = nil,
        confirmTitle: String,
        cancelTitle: String = "Cancel",
        defaultCancel: Bool = true,
        parentWindow: NSWindow? = nil
    ) -> Bool {
        let defaultIndex = defaultCancel ? 0 : 1
        let index = present(
            title: title,
            message: message,
            secondaryMessage: secondaryMessage,
            style: .warning,
            icon: .warning,
            buttons: [Button(cancelTitle, role: .dismissive), Button(confirmTitle)],
            defaultButtonIndex: defaultIndex,
            escapeButtonIndex: 0,
            parentWindow: parentWindow
        )
        return index == 1
    }

    /// Text-field prompt (rename, prefix entry, etc.).
    static func presentTextInput(
        title: String,
        message: String,
        initialText: String,
        fieldWidth: CGFloat = 280,
        confirmTitle: String = "OK",
        cancelTitle: String = "Cancel",
        defaultCancel: Bool = false
    ) -> String? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: fieldWidth, height: 24))
        field.stringValue = initialText

        let defaultIndex = defaultCancel ? 0 : 1
        let index = present(
            title: title,
            message: message,
            icon: .question,
            buttons: [Button(cancelTitle, role: .dismissive), Button(confirmTitle)],
            defaultButtonIndex: defaultIndex,
            escapeButtonIndex: 0,
            accessoryView: field,
            initialFirstResponder: field
        )
        guard index == 1 else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: - Layout / keyboard helpers

    private static func iconKind(for style: NSAlert.Style) -> IconKind {
        switch style {
        case .warning: return .warning
        case .critical: return .critical
        case .informational: return .information
        @unknown default: return .information
        }
    }

    fileprivate static func iconImage(for kind: IconKind) -> NSImage? {
        switch kind {
        case .none:
            return nil
        case .warning:
            return symbolImage("exclamationmark.triangle.fill", fallback: NSImage(named: NSImage.cautionName))
        case .critical:
            return symbolImage("xmark.octagon.fill", fallback: NSImage(named: NSImage.stopProgressFreestandingTemplateName))
        case .information:
            return symbolImage("info.circle.fill", fallback: NSImage(named: NSImage.infoName))
        case .question:
            return symbolImage("questionmark.circle.fill", fallback: NSImage(named: NSImage.cautionName))
        }
    }

    fileprivate static func symbolImage(_ name: String, fallback: NSImage?) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            return image.withSymbolConfiguration(config) ?? image
        }
        if let fallback {
            fallback.size = NSSize(width: 44, height: 44)
        }
        return fallback
    }

    private static func visualLeftToRightOrder(_ buttons: [Button]) -> [Button] {
        let leading = buttons.filter { $0.role == .dismissive }
        let trailing = buttons.filter { $0.role == .affirmative }
        return leading + trailing
    }

    private static func defaultVisualIndexForButtons(_ buttons: [Button]) -> Int? {
        let ordered = visualLeftToRightOrder(buttons)
        if let okIndex = ordered.firstIndex(where: { $0.title == "OK" }) {
            return okIndex
        }
        if ordered.count == 1 {
            return 0
        }
        return ordered.count - 1
    }

    private static func escapeVisualIndexForButtons(_ buttons: [Button]) -> Int? {
        let ordered = visualLeftToRightOrder(buttons)
        let dismissiveTitles = ["Cancel", "Close", "No"]
        for title in dismissiveTitles {
            if let index = ordered.firstIndex(where: { $0.title == title }) {
                return index
            }
        }
        return ordered.isEmpty ? nil : 0
    }

}

@MainActor
private final class StyledMessagePanelController: NSObject, NSWindowDelegate {
    let panel: NSPanel
    let buttonsLeftToRight: [NSButton]
    let escapeButton: NSButton?
    var selectedIndex: Int?
    private weak var sheetParent: NSWindow?

    init(
        title: String,
        message: String,
        secondaryMessage: String?,
        icon: StyledMessageDialog.IconKind,
        buttons: [StyledMessageDialog.Button],
        defaultButtonIndex: Int?,
        escapeButtonIndex: Int?,
        accessoryView: NSView?,
        initialFirstResponder: NSView?
    ) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        // Non-floating so the dialog becomes key window and buttons receive focus/arrow keys.
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .modalPanel
        panel.identifier = NSUserInterfaceItemIdentifier("styled-message-dialog")

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let messageColumn = NSStackView()
        messageColumn.orientation = .vertical
        messageColumn.alignment = .leading
        messageColumn.spacing = 10
        messageColumn.translatesAutoresizingMaskIntoConstraints = false

        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.isSelectable = true
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        messageLabel.setContentHuggingPriority(.defaultLow, for: .vertical)
        messageColumn.addArrangedSubview(messageLabel)

        if let secondaryMessage, !secondaryMessage.isEmpty {
            let secondaryLabel = NSTextField(wrappingLabelWithString: secondaryMessage)
            secondaryLabel.isSelectable = true
            secondaryLabel.lineBreakMode = .byWordWrapping
            secondaryLabel.textColor = .secondaryLabelColor
            secondaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            secondaryLabel.setContentHuggingPriority(.defaultLow, for: .vertical)
            messageColumn.addArrangedSubview(secondaryLabel)
        }

        if let accessoryView {
            accessoryView.translatesAutoresizingMaskIntoConstraints = false
            messageColumn.addArrangedSubview(accessoryView)
            accessoryView.widthAnchor.constraint(equalTo: messageColumn.widthAnchor).isActive = true
        }

        let bodyRow = NSStackView()
        bodyRow.orientation = .horizontal
        bodyRow.alignment = .top
        bodyRow.spacing = 12
        bodyRow.translatesAutoresizingMaskIntoConstraints = false

        if let iconImage = StyledMessageDialog.iconImage(for: icon) {
            let iconView = NSImageView()
            iconView.image = iconImage
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.setContentHuggingPriority(.required, for: .horizontal)
            iconView.setContentHuggingPriority(.required, for: .vertical)
            NSLayoutConstraint.activate([
                iconView.widthAnchor.constraint(equalToConstant: 44),
                iconView.heightAnchor.constraint(equalToConstant: 44),
            ])
            bodyRow.addArrangedSubview(iconView)
        }

        bodyRow.addArrangedSubview(messageColumn)

        let leadingButtons = NSStackView()
        leadingButtons.orientation = .horizontal
        leadingButtons.spacing = 8
        leadingButtons.translatesAutoresizingMaskIntoConstraints = false

        let trailingButtons = NSStackView()
        trailingButtons.orientation = .horizontal
        trailingButtons.spacing = 8
        trailingButtons.translatesAutoresizingMaskIntoConstraints = false

        var builtButtons: [NSButton] = []
        for (index, spec) in buttons.enumerated() {
            let button = FocusableDialogButton(title: spec.title, target: nil, action: nil)
            button.bezelStyle = .rounded
            button.focusRingType = .default
            button.tag = index
            button.translatesAutoresizingMaskIntoConstraints = false
            builtButtons.append(button)
            switch spec.role {
            case .dismissive:
                leadingButtons.addArrangedSubview(button)
            case .affirmative:
                trailingButtons.addArrangedSubview(button)
            }
        }
        buttonsLeftToRight = builtButtons
        if builtButtons.count >= 2 {
            for index in 0 ..< builtButtons.count - 1 {
                builtButtons[index].nextKeyView = builtButtons[index + 1]
            }
            builtButtons[builtButtons.count - 1].nextKeyView = builtButtons[0]
        }
        escapeButton = escapeButtonIndex.flatMap { index in
            guard index >= 0, index < builtButtons.count else { return nil }
            return builtButtons[index]
        }

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.addArrangedSubview(leadingButtons)
        buttonRow.addArrangedSubview(NSView())
        buttonRow.addArrangedSubview(trailingButtons)

        content.addSubview(bodyRow)
        content.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            bodyRow.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            bodyRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            bodyRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),

            messageColumn.widthAnchor.constraint(greaterThanOrEqualToConstant: icon == .none ? 296 : 240),

            buttonRow.topAnchor.constraint(equalTo: bodyRow.bottomAnchor, constant: 18),
            buttonRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
        ])

        panel.contentView = content
        panel.contentMinSize = NSSize(width: 340, height: 120)

        super.init()

        panel.delegate = self

        for button in builtButtons {
            button.target = self
            button.action = #selector(buttonPressed(_:))
        }

        if let defaultButtonIndex,
           defaultButtonIndex >= 0,
           defaultButtonIndex < builtButtons.count {
            builtButtons[defaultButtonIndex].keyEquivalent = "\r"
            panel.initialFirstResponder = initialFirstResponder ?? builtButtons[defaultButtonIndex]
        } else if let initialFirstResponder {
            panel.initialFirstResponder = initialFirstResponder
        }
    }

    func runModal(parentWindow: NSWindow? = nil) {
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        if let parentWindow {
            sheetParent = parentWindow
            parentWindow.makeKeyAndOrderFront(nil)
            parentWindow.beginSheet(panel) { [weak self] _ in
                self?.sheetParent = nil
            }
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        if let firstResponder = panel.initialFirstResponder ?? buttonsLeftToRight.first {
            panel.makeFirstResponder(firstResponder)
        }
        NSApp.runModal(for: panel)
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        selectedIndex = sender.tag
        close()
    }

    private func close() {
        if let sheetParent {
            sheetParent.endSheet(panel)
            self.sheetParent = nil
        } else {
            panel.orderOut(nil)
        }
        NSApp.stopModal()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let escapeButton {
            escapeButton.performClick(nil)
        } else {
            selectedIndex = buttonsLeftToRight.indices.last
            close()
        }
        return false
    }
}
