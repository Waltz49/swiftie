import AppKit

/// Tools → Debug → Show EXIF API structure — JSON snapshot of ``ExifCommentData`` for the active image.
@MainActor
final class ExifAPIStructureDialogController: NSObject, NSWindowDelegate {
    private static let wrapKey = "exif_api_structure_wrap"
    private static let textFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private static var activeInstance: ExifAPIStructureDialogController?

    private weak var appState: AppState?
    private var panel: NSPanel?
    private var textView: NSTextView?
    private var wrapCheckbox: NSButton?
    private var keyboardMonitor: Any?

    static func show(appState: AppState) {
        if let existing = activeInstance, existing.panel != nil {
            existing.reload(appState: appState)
            existing.raise()
            return
        }
        let controller = ExifAPIStructureDialogController()
        activeInstance = controller
        controller.present(appState: appState)
    }

    private func raise() {
        guard let panel else { return }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func present(appState: AppState) {
        self.appState = appState
        let config = appState.config

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = Self.textFont
        textView.drawsBackground = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.documentView = textView
        self.textView = textView

        let wrapCheckbox = NSButton(checkboxWithTitle: "Wrap", target: self, action: #selector(wrapToggled))
        wrapCheckbox.state = config.bool(forKey: Self.wrapKey, default: true) ? .on : .off
        applyWrap(wrapCheckbox.state == .on)
        self.wrapCheckbox = wrapCheckbox

        let refreshButton = FocusableDialogButton(title: "Refresh", target: self, action: #selector(refreshClicked))
        let copyButton = FocusableDialogButton(title: "Copy", target: self, action: #selector(copyJSON))
        let closeButton = FocusableDialogButton(title: "Close", target: self, action: #selector(closeClicked))
        closeButton.keyEquivalent = "\r"

        let buttonRow = NSStackView(views: [wrapCheckbox, NSView(), refreshButton, copyButton, closeButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY
        buttonRow.setViews([wrapCheckbox], in: .leading)
        buttonRow.setViews([refreshButton, copyButton, closeButton], in: .trailing)
        if let spacer = buttonRow.views.first(where: { $0 !== wrapCheckbox && !($0 is NSButton) }) {
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        let content = NSStackView(views: [scrollView, buttonRow])
        content.orientation = .vertical
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        content.autoresizingMask = [.width, .height]
        content.distribution = .fill
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "EXIF API Structure"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 520, height: 360)
        panel.contentView = content
        panel.delegate = self
        self.panel = panel

        DialogGeometryPersistence.apply(
            to: panel,
            config: config,
            key: DialogGeometryKey.exifAPIStructure,
            defaultSize: NSSize(width: 820, height: 520),
            minSize: NSSize(width: 520, height: 360)
        )

        keyboardMonitor = AppKitDialogKeyboardNavigation.install(
            on: panel,
            buttonsLeftToRight: [refreshButton, copyButton, closeButton],
            escapeButton: closeButton
        )

        installCopyFeedbackOverlay(on: panel, appState: appState)

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Load after the panel has a real content rect (stack view / wrap width need layout).
        DispatchQueue.main.async { [weak self] in
            self?.reload(appState: appState)
        }
    }

    private func reload(appState: AppState) {
        self.appState = appState
        guard let textView else { return }
        let json: String
        if let path = appState.fileData.currentImagePath {
            panel?.subtitle = (path as NSString).lastPathComponent
            json = ExifCommentData.debugReportJSONString(for: path)
        } else {
            panel?.subtitle = ""
            json = "{\n  \"error\": \"No active image\"\n}"
        }
        textView.string = json
        if let wrapCheckbox {
            applyWrap(wrapCheckbox.state == .on)
        }
        refreshTextLayout(stickToTop: true)
    }

    private func refreshTextLayout(stickToTop: Bool) {
        guard let textView, let scrollView = textView.enclosingScrollView else { return }
        guard let container = textView.textContainer, let layoutManager = textView.layoutManager else { return }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        var frame = textView.frame
        let trackWidth = scrollView.contentSize.width
        if textView.isHorizontallyResizable {
            frame.size.width = max(trackWidth, used.width)
        } else {
            frame.size.width = trackWidth
        }
        frame.size.height = max(used.height, scrollView.contentSize.height)
        textView.frame = frame
        if stickToTop {
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
    }

    @objc private func refreshClicked() {
        guard let appState else { return }
        reload(appState: appState)
    }

    @objc private func copyJSON() {
        guard let appState, let text = textView?.string, !text.isEmpty else { return }
        appState.copyTextToClipboard(text, hostWindow: panel)
    }

    @objc private func wrapToggled() {
        guard let appState, let wrapCheckbox else { return }
        let wrapped = wrapCheckbox.state == .on
        appState.config.updateSetting(Self.wrapKey, value: wrapped)
        applyWrap(wrapped)
        refreshTextLayout(stickToTop: false)
    }

    private func applyWrap(_ wrapped: Bool) {
        guard let textView, let scrollView = textView.enclosingScrollView else { return }
        let wrapWidth = max(textView.bounds.width, scrollView.contentSize.width, 320)
        if wrapped {
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.containerSize = NSSize(
                width: wrapWidth,
                height: CGFloat.greatestFiniteMagnitude
            )
        } else {
            textView.isHorizontallyResizable = true
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
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
        if let panel, let appState {
            DialogGeometryPersistence.saveFrame(
                config: appState.config,
                key: DialogGeometryKey.exifAPIStructure,
                frame: panel.frame
            )
        }
        panel = nil
        if Self.activeInstance === self {
            Self.activeInstance = nil
        }
    }
}
