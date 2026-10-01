import AppKit
import UniformTypeIdentifiers

/// Tools → Debug → View log — live session log viewer (port of `print_log_dialog.py`).
@MainActor
final class ViewLogDialogController: NSObject, NSWindowDelegate {
    private static let geometryKey = "view_print_log_dialog_geometry"
    private static let wrapKey = "view_print_log_wrap"
    private static let pollInterval: TimeInterval = 0.3
    private static let logBackground = NSColor.black
    private static let logText = NSColor.white
    private static let logFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// Strong reference for the panel lifetime (buttons target `self`; weak ref deallocates before Close works).
    private static var activeInstance: ViewLogDialogController?

    private weak var appState: AppState?
    private var panel: NSPanel?
    private var textView: NSTextView?
    private var wrapCheckbox: NSButton?
    private var fileOffset: UInt64 = 0
    private var pollTimer: Timer?
    private var keyboardMonitor: Any?
    private var logAppendObserver: NSObjectProtocol?

    static func show(appState: AppState) {
        if let existing = activeInstance, existing.panel != nil {
            existing.resyncFromLogFile(appState: appState)
            existing.raise()
            return
        }
        let controller = ViewLogDialogController()
        activeInstance = controller
        controller.present(appState: appState)
    }

    static func resyncIfOpen(appState: AppState) {
        guard let existing = activeInstance, existing.panel != nil else { return }
        existing.resyncFromLogFile(appState: appState)
    }

    private func raise() {
        guard let panel else { return }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func resyncFromLogFile(appState: AppState) {
        self.appState = appState
        reloadAllFromDisk(appState: appState)
    }

    private func reloadAllFromDisk(appState: AppState) {
        let url = appState.sessionViewLogURL
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        textView?.string = ""
        fileOffset = 0
        if !text.isEmpty, let textView {
            setFullLogText(text, textView: textView)
        }
        syncFileOffsetToDiskEnd(appState: appState)
        refreshLogTextLayout(stickToBottom: true)
    }

    private func syncFileOffsetToDiskEnd(appState: AppState) {
        let url = appState.sessionViewLogURL
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        fileOffset = size
    }

    private func installLogAppendObserver() {
        logAppendObserver = NotificationCenter.default.addObserver(
            forName: .sessionViewLogDidAppend,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.handleLogAppendNotification(note)
            }
        }
    }

    private func handleLogAppendNotification(_ note: Notification) {
        guard let appState,
              let url = note.userInfo?[SessionViewLog.appendNotificationURLKey] as? URL,
              textView != nil else { return }
        guard url.standardizedFileURL.path == appState.sessionViewLogURL.standardizedFileURL.path else { return }
        // Append via file offset only — avoid duplicating lines already shown by the poll timer.
        appendFromFile(stickToBottom: isAtBottom())
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
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        self.textView = textView

        let wrapCheckbox = NSButton(checkboxWithTitle: "Wrap", target: self, action: #selector(wrapToggled))
        wrapCheckbox.state = config.bool(forKey: Self.wrapKey, default: false) ? .on : .off
        applyWrap(wrapCheckbox.state == .on)
        self.wrapCheckbox = wrapCheckbox

        let clearButton = FocusableDialogButton(title: "Clear", target: self, action: #selector(clearLog))
        let saveButton = FocusableDialogButton(title: "Save", target: self, action: #selector(saveLog))
        let closeButton = FocusableDialogButton(title: "Close", target: self, action: #selector(closeClicked))
        closeButton.keyEquivalent = "\r"

        let buttonRow = NSStackView(views: [wrapCheckbox, NSView(), clearButton, saveButton, closeButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY
        buttonRow.setViews([wrapCheckbox], in: .leading)
        buttonRow.setViews([clearButton, saveButton, closeButton], in: .trailing)
        if let spacer = buttonRow.views.first(where: { $0 !== wrapCheckbox && !($0 is NSButton) }) {
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
        panel.title = "View Log"
        panel.subtitle = ProwserTempFiles.displayPath(appState.sessionViewLogURL.path)
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
            key: Self.geometryKey,
            defaultSize: NSSize(width: 820, height: 520),
            minSize: NSSize(width: 520, height: 360)
        )

        keyboardMonitor = AppKitDialogKeyboardNavigation.install(
            on: panel,
            buttonsLeftToRight: [clearButton, saveButton, closeButton],
            escapeButton: closeButton
        )

        fileOffset = 0
        installLogAppendObserver()
        // Load after the panel has a real content rect (stack view needs layout pass).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadAllFromDisk(appState: appState)
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollLog()
            }
        }
        if let pollTimer {
            RunLoop.main.add(pollTimer, forMode: .common)
        }

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func pollLog() {
        let stick = isAtBottom()
        appendFromFile(stickToBottom: stick)
    }

    private func appendFromFile(stickToBottom: Bool) {
        guard let appState, let textView else { return }
        let chunk = SessionViewLog.readChunk(logFileURL: appState.sessionViewLogURL, offset: &fileOffset)
        guard !chunk.isEmpty else { return }
        appendText(chunk, stickToBottom: stickToBottom, textView: textView)
        refreshLogTextLayout(stickToBottom: stickToBottom)
    }

    private static var logTextAttributes: [NSAttributedString.Key: Any] {
        [
            .foregroundColor: logText,
            .font: logFont,
        ]
    }

    private func setFullLogText(_ text: String, textView: NSTextView) {
        let attrs = Self.logTextAttributes
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attrs))
        textView.font = Self.logFont
        textView.textColor = Self.logText
        textView.backgroundColor = Self.logBackground
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

    private func appendText(_ text: String, stickToBottom: Bool, textView: NSTextView) {
        guard !text.isEmpty else { return }
        let attrs = Self.logTextAttributes
        if let storage = textView.textStorage {
            storage.append(NSAttributedString(string: text, attributes: attrs))
        } else {
            textView.string += text
            textView.font = Self.logFont
            textView.textColor = Self.logText
        }
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

    @objc private func wrapToggled() {
        let wrapped = wrapCheckbox?.state == .on
        applyWrap(wrapped)
        appState?.config.updateSetting(Self.wrapKey, value: wrapped)
    }

    private func applyWrap(_ wrapped: Bool) {
        guard let textView else { return }
        if wrapped {
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.containerSize = NSSize(
                width: textView.bounds.width,
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

    @objc private func clearLog() {
        guard let appState else { return }
        SessionViewLog.clear(logFileURL: appState.sessionViewLogURL)
        textView?.string = ""
        fileOffset = 0
    }

    @objc private func saveLog() {
        guard let appState else { return }
        let source = appState.sessionViewLogURL
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = formatter.string(from: Date())
        let defaultURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?
            .appendingPathComponent("image_browser_session_\(stamp).txt")
        let panel = NSSavePanel()
        panel.title = "Save Log"
        panel.nameFieldStringValue = defaultURL?.lastPathComponent ?? "prowser_log.txt"
        panel.directoryURL = defaultURL?.deletingLastPathComponent()
        panel.allowedContentTypes = [.plainText]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                try FileManager.default.copyItem(at: source, to: url)
            } catch {
                StyledMessageDialog.showWarning(
                    title: "Save Log",
                    message: "Could not save log:\n\(error.localizedDescription)"
                )
            }
            _ = self
        }
    }

    @objc private func closeClicked() {
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
        if let logAppendObserver {
            NotificationCenter.default.removeObserver(logAppendObserver)
            self.logAppendObserver = nil
        }
        if let monitor = keyboardMonitor {
            NSEvent.removeMonitor(monitor)
            keyboardMonitor = nil
        }
        if let panel {
            DialogGeometryPersistence.saveFrame(
                config: appState!.config,
                key: Self.geometryKey,
                frame: panel.frame
            )
        }
        panel = nil
        if Self.activeInstance === self {
            Self.activeInstance = nil
        }
    }
}
