import AppKit
import QuartzCore

/// Determinate, non-cancellable progress panel used by synchronous batch operations.
/// Port of the Python `QProgressDialog(..., cancelButton=None)` usage in
/// `file_operations_manager.py` (label text is middle-elided like `wrap_progress_dialog_label_elision`).
///
/// The caller drives it synchronously on the main thread; `refresh()` paints the panel without
/// spinning the run loop (the Swift equivalent of `QApplication.processEvents()` for display only,
/// which avoids re-entrant directory refreshes while files are being renamed).
@MainActor
final class ProgressPanelController {
    private static let lineMaxChars = 64  // utils.PROGRESS_LINE_MAX_CHARS
    private static let labelMaxWidth: CGFloat = 400  // utils.PROGRESS_LABEL_MAX_WIDTH_PX

    private let panel: NSPanel
    private let label: NSTextField
    private let indicator: NSProgressIndicator

    init(title: String, labelText: String, maximum: Int) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 96),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isFloatingPanel = true
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

        let content = NSView()
        content.wantsLayer = true
        content.addSubview(label)
        content.addSubview(indicator)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: Self.labelMaxWidth),
            indicator.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
            indicator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            indicator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            indicator.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        panel.contentView = content
        setLabel(labelText)
    }

    func show() {
        panel.center()
        panel.orderFrontRegardless()
        refresh()
    }

    func close() {
        panel.orderOut(nil)
    }

    func setMaximum(_ maximum: Int) {
        indicator.maxValue = Double(max(1, maximum))
    }

    func setValue(_ value: Int) {
        indicator.doubleValue = Double(value)
    }

    func setLabel(_ text: String) {
        label.stringValue = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { RenamePrefixPlanner.elideMiddle(String($0), maxLen: Self.lineMaxChars) }
            .joined(separator: "\n")
    }

    /// Update value + label and paint immediately.
    func update(value: Int? = nil, label text: String? = nil) {
        if let value { setValue(value) }
        if let text { setLabel(text) }
        refresh()
    }

    /// Paint pending changes without processing input events.
    func refresh() {
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        CATransaction.flush()
    }
}
