import AppKit

@MainActor
final class LoRADefaultsImportSummaryDialogController: NSObject, NSWindowDelegate {
    private static let textFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static var activeInstance: LoRADefaultsImportSummaryDialogController?

    private weak var appState: AppState?
    private var panel: NSPanel?
    private var textView: NSTextView?
    private var keyboardMonitor: Any?

    static func show(summary: String, appState: AppState) {
        if let existing = activeInstance, existing.panel != nil {
            existing.appState = appState
            existing.setText(summary)
            existing.raise()
            return
        }
        let controller = LoRADefaultsImportSummaryDialogController()
        activeInstance = controller
        controller.present(summary: summary, appState: appState)
    }

    private func raise() {
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setText(_ text: String) {
        textView?.string = text
    }

    private func present(summary: String, appState: AppState) {
        self.appState = appState
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = Self.textFont
        textView.string = summary
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        self.textView = textView

        let copyButton = FocusableDialogButton(title: "Copy", target: self, action: #selector(copySummary))
        let closeButton = FocusableDialogButton(title: "Close", target: self, action: #selector(closeClicked))
        closeButton.keyEquivalent = "\r"

        let buttonRow = NSStackView(views: [copyButton, NSView(), closeButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.setViews([copyButton], in: .leading)
        buttonRow.setViews([closeButton], in: .trailing)
        if let spacer = buttonRow.views.first(where: { !($0 is NSButton) }) {
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        let content = NSStackView(views: [scrollView, buttonRow])
        content.orientation = .vertical
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Import Lora Defaults"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 400, height: 280)
        panel.contentView = content
        panel.delegate = self
        self.panel = panel

        keyboardMonitor = AppKitDialogKeyboardNavigation.install(
            on: panel,
            buttonsLeftToRight: [copyButton, closeButton],
            escapeButton: closeButton
        )

        installCopyFeedbackOverlay(on: panel, appState: appState)

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func copySummary() {
        guard let appState, let text = textView?.string, !text.isEmpty else { return }
        appState.copyTextToClipboard(text, hostWindow: panel)
    }

    @objc private func closeClicked() {
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        if let monitor = keyboardMonitor {
            NSEvent.removeMonitor(monitor)
            keyboardMonitor = nil
        }
        if Self.activeInstance === self {
            Self.activeInstance = nil
        }
    }
}