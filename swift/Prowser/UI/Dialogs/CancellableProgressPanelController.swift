import AppKit

/// Determinate progress panel with Cancel (port of Python `QProgressDialog` with cancel for resize batch).
@MainActor
final class CancellableProgressPanelController {
    private static let lineMaxChars = 64
    private static let labelMaxWidth: CGFloat = 400

    private let panel: NSPanel
    private let label: NSTextField
    private let indicator: NSProgressIndicator
    private let cancelButton: FocusableDialogButton
    private let cancelTarget = CancelTarget()
    private var keyboardMonitor: Any?
    private var isClosed = false
    private(set) var cancelRequested = false

    init(title: String, labelText: String, maximum: Int) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .modalPanel

        label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byClipping
        label.usesSingleLineMode = false
        label.maximumNumberOfLines = 3
        label.translatesAutoresizingMaskIntoConstraints = false

        indicator = NSProgressIndicator()
        indicator.style = .bar
        indicator.isIndeterminate = false
        indicator.minValue = 0
        indicator.maxValue = Double(max(1, maximum))
        indicator.doubleValue = 0
        indicator.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = FocusableDialogButton(title: "Cancel", target: cancelTarget, action: #selector(CancelTarget.tapped))
        cancelButton.bezelStyle = .rounded
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        self.cancelButton = cancelButton
        cancelTarget.onCancel = { [weak self] in
            self?.cancelRequested = true
        }

        let content = NSView()
        content.wantsLayer = true
        content.addSubview(label)
        content.addSubview(indicator)
        content.addSubview(cancelButton)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: Self.labelMaxWidth),
            indicator.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
            indicator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            indicator.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -12),
            cancelButton.centerYAnchor.constraint(equalTo: indicator.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            indicator.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        panel.contentView = content
        setLabel(labelText)
    }

    func show() {
        panel.center()
        keyboardMonitor = AppKitDialogKeyboardNavigation.install(
            on: panel,
            buttonsLeftToRight: [cancelButton],
            escapeButton: cancelButton
        )
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(cancelButton)
        refresh()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.panel.makeKeyAndOrderFront(nil)
            self.panel.makeFirstResponder(self.cancelButton)
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
        }
        keyboardMonitor = nil
        panel.orderOut(nil)
    }

    func setMaximum(_ maximum: Int) {
        guard !isClosed else { return }
        indicator.maxValue = Double(max(1, maximum))
    }

    func setValue(_ value: Int) {
        guard !isClosed else { return }
        indicator.doubleValue = Double(value)
    }

    func setLabel(_ text: String) {
        guard !isClosed else { return }
        label.stringValue = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { RenamePrefixPlanner.elideMiddle(String($0), maxLen: Self.lineMaxChars) }
            .joined(separator: "\n")
    }

    func update(value: Int? = nil, label text: String? = nil) {
        if let value { setValue(value) }
        if let text { setLabel(text) }
        refresh()
    }

    func refresh() {
        guard !isClosed else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
    }

    private final class CancelTarget: NSObject {
        var onCancel: (() -> Void)?

        @objc func tapped() {
            onCancel?()
        }
    }
}
