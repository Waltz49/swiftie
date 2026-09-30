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
    private let timeRemainingLabel: NSTextField?
    private let indicator: NSProgressIndicator
    private let showsTimeRemainingEstimate: Bool
    private var progressStartDate: Date?
    private var etaTimer: Timer?
    private let etaTimerTarget = ETATimerTarget()
    private var pendingValue: Int?
    private var pendingLabel: String?
    private var lastProgressUIEmitDate: Date?

    init(title: String, labelText: String, maximum: Int, showsTimeRemainingEstimate: Bool = true) {
        self.showsTimeRemainingEstimate = showsTimeRemainingEstimate
        let panelHeight: CGFloat = showsTimeRemainingEstimate ? 120 : 96

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: panelHeight),
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

        let timeRemaining: NSTextField?
        if showsTimeRemainingEstimate {
            let eta = NSTextField(labelWithString: "")
            eta.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            eta.textColor = .secondaryLabelColor
            eta.lineBreakMode = .byTruncatingTail
            eta.maximumNumberOfLines = 1
            eta.translatesAutoresizingMaskIntoConstraints = false
            timeRemaining = eta
        } else {
            timeRemaining = nil
        }
        timeRemainingLabel = timeRemaining

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
        if let timeRemaining {
            content.addSubview(timeRemaining)
        }
        content.addSubview(indicator)

        let progressTopAnchor: NSLayoutYAxisAnchor
        if let timeRemaining {
            progressTopAnchor = timeRemaining.bottomAnchor
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
                label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                label.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
                label.widthAnchor.constraint(lessThanOrEqualToConstant: Self.labelMaxWidth),
                timeRemaining.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
                timeRemaining.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                timeRemaining.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
                timeRemaining.heightAnchor.constraint(equalToConstant: 16),
                indicator.topAnchor.constraint(equalTo: progressTopAnchor, constant: 6),
            ])
        } else {
            progressTopAnchor = label.bottomAnchor
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
                label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                label.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
                label.widthAnchor.constraint(lessThanOrEqualToConstant: Self.labelMaxWidth),
                indicator.topAnchor.constraint(equalTo: progressTopAnchor, constant: 10),
            ])
        }

        NSLayoutConstraint.activate([
            indicator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            indicator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            indicator.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        panel.contentView = content
        setLabel(labelText)
    }

    func show() {
        progressStartDate = Date()
        if showsTimeRemainingEstimate {
            startETATimer()
        }
        panel.center()
        panel.orderFrontRegardless()
        refresh()
    }

    func close() {
        if pendingValue != nil || pendingLabel != nil {
            flushPending()
        }
        etaTimer?.invalidate()
        etaTimer = nil
        progressStartDate = nil
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

    /// Immediate label change (e.g. phase transitions) without waiting for the progress throttle.
    func updateStatus(label text: String) {
        setLabel(text)
        refresh()
    }

    /// Coalesced value + label update (at most once per `ProgressDialogTiming.progressUpdateInterval`).
    func update(value: Int? = nil, label text: String? = nil) {
        if let value { pendingValue = value }
        if let text { pendingLabel = text }
        let interval = ProgressDialogTiming.progressUpdateInterval
        if shouldFlushImmediately(value: pendingValue, interval: interval) {
            flushPending()
        }
    }

    /// Paint pending changes without processing input events.
    func refresh() {
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        CATransaction.flush()
    }

    private func flushPending() {
        if let value = pendingValue {
            setValue(value)
            pendingValue = nil
        }
        if let text = pendingLabel {
            setLabel(text)
            pendingLabel = nil
        }
        lastProgressUIEmitDate = Date()
        refresh()
    }

    private func shouldFlushImmediately(value: Int?, interval: TimeInterval) -> Bool {
        let effectiveValue = value ?? pendingValue
        if let effectiveValue, effectiveValue >= Int(indicator.maxValue.rounded()) {
            return true
        }
        guard let last = lastProgressUIEmitDate else { return true }
        return Date().timeIntervalSince(last) >= interval
    }

    private func startETATimer() {
        etaTimerTarget.owner = self
        let timer = Timer(
            timeInterval: ProgressDialogTiming.estimateRefreshInterval,
            target: etaTimerTarget,
            selector: #selector(ETATimerTarget.tick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        etaTimer = timer
    }

    private func refreshTimeRemainingEstimate() {
        guard let timeRemainingLabel, let start = progressStartDate else { return }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed >= ProgressDialogTiming.estimateWarmupInterval else {
            timeRemainingLabel.stringValue = ""
            return
        }
        let completed = indicator.doubleValue
        let total = indicator.maxValue
        guard completed > 0, total > completed else {
            timeRemainingLabel.stringValue = ""
            return
        }
        let remaining = (elapsed / completed) * (total - completed)
        guard remaining > 0 else {
            timeRemainingLabel.stringValue = ""
            return
        }
        timeRemainingLabel.stringValue =
            "About \(ProgressDialogTiming.formatRemainingDuration(remaining)) remaining"
        refresh()
    }

    private final class ETATimerTarget: NSObject {
        weak var owner: ProgressPanelController?

        @MainActor @objc func tick() {
            owner?.refreshTimeRemainingEstimate()
        }
    }
}
