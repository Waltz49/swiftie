import AppKit

/// Live output for Settings → Image Generation → Install dependencies….
@MainActor
final class ImageGenVenvInstallOutputDialogController: NSObject, NSWindowDelegate {
    private static let logBackground = NSColor.black
    private static let logText = NSColor.white
    private static let logFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private static var activeInstance: ImageGenVenvInstallOutputDialogController?

    private var panel: NSPanel?
    private var textView: NSTextView?
    private var copyStatusLabel: NSTextField?
    private var keyboardMonitor: Any?

    /// Opens or reuses the panel and clears text for a new install session.
    static func beginNewSession() -> ImageGenVenvInstallOutputDialogController {
        if let existing = activeInstance, existing.panel != nil {
            existing.clearText()
            existing.raise()
            return existing
        }
        let controller = ImageGenVenvInstallOutputDialogController()
        activeInstance = controller
        controller.present()
        return controller
    }

    func append(_ text: String) {
        guard let textView, !text.isEmpty else { return }
        let stick = isAtBottom()
        let attrs = Self.logTextAttributes
        if let storage = textView.textStorage {
            storage.append(NSAttributedString(string: text, attributes: attrs))
        } else {
            textView.string += text
            textView.font = Self.logFont
            textView.textColor = Self.logText
        }
        refreshLogTextLayout(stickToBottom: stick)
        if stick {
            textView.scrollToEndOfDocument(nil)
        }
    }

    private func clearText() {
        textView?.string = ""
        copyStatusLabel?.stringValue = ""
        refreshLogTextLayout(stickToBottom: true)
    }

    private func raise() {
        guard let panel else { return }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func present() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Self.logBackground

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = Self.logFont
        textView.textColor = Self.logText
        textView.backgroundColor = Self.logBackground
        textView.drawsBackground = true
        textView.insertionPointColor = Self.logText
        textView.typingAttributes = Self.logTextAttributes
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.documentView = textView
        self.textView = textView

        let copyStatusLabel = NSTextField(labelWithString: "")
        copyStatusLabel.font = .systemFont(ofSize: 11)
        copyStatusLabel.textColor = .secondaryLabelColor
        self.copyStatusLabel = copyStatusLabel

        let copyButton = FocusableDialogButton(title: "Copy", target: self, action: #selector(copyClicked))
        let closeButton = FocusableDialogButton(title: "Close", target: self, action: #selector(closeClicked))
        closeButton.keyEquivalent = "\r"

        let buttonRow = NSStackView(views: [copyButton, copyStatusLabel, NSView(), closeButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY
        buttonRow.setViews([copyButton, copyStatusLabel], in: .leading)
        buttonRow.setViews([closeButton], in: .trailing)
        if let spacer = buttonRow.views.first(where: { $0 !== copyButton && $0 !== copyStatusLabel && !($0 is NSButton) }) {
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        let content = NSStackView(views: [scrollView, buttonRow])
        content.orientation = .vertical
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        content.autoresizingMask = [.width, .height]
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Install imagegen dependencies"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 520, height: 360)
        panel.contentView = content
        panel.delegate = self
        self.panel = panel

        keyboardMonitor = AppKitDialogKeyboardNavigation.install(
            on: panel,
            buttonsLeftToRight: [copyButton, closeButton],
            escapeButton: closeButton
        )

        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static var logTextAttributes: [NSAttributedString.Key: Any] {
        [
            .foregroundColor: logText,
            .font: logFont,
        ]
    }

    private func refreshLogTextLayout(stickToBottom: Bool) {
        guard let textView, let scrollView = textView.enclosingScrollView else { return }
        guard let container = textView.textContainer, let layoutManager = textView.layoutManager else { return }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        var frame = textView.frame
        frame.size.width = max(scrollView.contentSize.width, used.width)
        frame.size.height = max(used.height, scrollView.contentSize.height)
        textView.frame = frame
        if stickToBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }

    private func isAtBottom() -> Bool {
        guard let scrollView = textView?.enclosingScrollView else { return true }
        let clip = scrollView.contentView
        let visible = clip.documentVisibleRect
        let docHeight = scrollView.documentView?.frame.height ?? 0
        return visible.maxY >= docHeight - 4
    }

    @objc private func copyClicked() {
        guard let textView else { return }
        let text = textView.string
        guard !text.isEmpty else {
            setCopyStatus(success: false, empty: true)
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        let ok = pb.setString(text, forType: .string)
        setCopyStatus(success: ok, empty: false)
    }

    private func setCopyStatus(success: Bool, empty: Bool) {
        guard let copyStatusLabel else { return }
        if empty {
            copyStatusLabel.stringValue = "Nothing to copy."
            copyStatusLabel.textColor = .secondaryLabelColor
            return
        }
        if success {
            copyStatusLabel.stringValue = "Copied."
            copyStatusLabel.textColor = .systemGreen
        } else {
            copyStatusLabel.stringValue = "Copy failed."
            copyStatusLabel.textColor = .systemRed
        }
    }

    @objc private func closeClicked() {
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        if let monitor = keyboardMonitor {
            NSEvent.removeMonitor(monitor)
            keyboardMonitor = nil
        }
        panel = nil
        if Self.activeInstance === self {
            Self.activeInstance = nil
        }
    }
}
