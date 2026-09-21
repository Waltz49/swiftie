import AppKit

/// Delayed hover tooltip styled like Python `job_prompt_tooltip._PromptTooltipPopup`.
@MainActor
final class ListPromptTooltip {
    static let shared = ListPromptTooltip()

    private let panel: NSPanel
    private let label: NSTextField
    private var showTask: Task<Void, Never>?
    private var activeHost: NSView?

    private init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]

        label = NSTextField(wrappingLabelWithString: "")
        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        label.drawsBackground = false
        label.font = NSFont.systemFont(ofSize: 12)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.preferredMaxLayoutWidth = 520
        label.translatesAutoresizingMaskIntoConstraints = false

        let chrome = NSView()
        chrome.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: chrome.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: chrome.bottomAnchor, constant: -8),
        ])
        panel.contentView = chrome
    }

    func scheduleShow(text: String, colors: ThemeColors, anchorView: NSView, delayMs: Int = 1000) {
        cancelPending()
        activeHost = anchorView
        let delayNs = UInt64(max(0, delayMs)) * 1_000_000
        showTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNs)
            guard !Task.isCancelled else { return }
            present(text: text, colors: colors, anchorView: anchorView)
        }
    }

    func hide(for host: NSView? = nil) {
        if let host, activeHost !== host { return }
        cancelPending()
        activeHost = nil
        panel.orderOut(nil)
    }

    private func cancelPending() {
        showTask?.cancel()
        showTask = nil
    }

    private func present(text: String, colors: ThemeColors, anchorView: NSView) {
        guard !text.isEmpty else { return }
        label.stringValue = text
        label.textColor = NSColor(colors.text)
        if let chrome = panel.contentView {
            chrome.wantsLayer = true
            chrome.layer?.backgroundColor = NSColor(colors.dialogBackground).cgColor
            chrome.layer?.borderColor = NSColor(colors.defaultBorder).cgColor
            chrome.layer?.borderWidth = 1
            chrome.layer?.cornerRadius = 4
        }
        let maxWidth = min(520, max(160, (anchorView.window?.frame.width ?? 800) - 40))
        label.preferredMaxLayoutWidth = maxWidth
        panel.contentView?.layoutSubtreeIfNeeded()
        let fitting = panel.contentView?.fittingSize ?? NSSize(width: maxWidth, height: 80)
        panel.setContentSize(NSSize(width: min(maxWidth + 20, fitting.width), height: fitting.height))

        guard let window = anchorView.window else { return }
        let anchorRect = anchorView.convert(anchorView.bounds, to: nil)
        let screenRect = window.convertToScreen(anchorRect)
        var origin = NSPoint(x: screenRect.midX - panel.frame.width / 2, y: screenRect.minY - panel.frame.height - 8)
        if let screen = window.screen?.visibleFrame {
            origin.x = max(screen.minX + 8, min(origin.x, screen.maxX - panel.frame.width - 8))
            origin.y = max(screen.minY + 8, min(origin.y, screen.maxY - panel.frame.height - 8))
        }
        panel.setFrameOrigin(origin)
        panel.orderFront(nil)
    }
}
