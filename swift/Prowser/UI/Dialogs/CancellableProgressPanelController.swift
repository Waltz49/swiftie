import AppKit

/// Determinate progress panel with Cancel (port of Python `QProgressDialog` with cancel for resize batch).
@MainActor
final class CancellableProgressPanelController {
    private static let lineMaxChars = 64
    private static let labelMaxWidth: CGFloat = 400
    private static let etaWarmupSeconds: TimeInterval = 5
    private static let etaRefreshInterval: TimeInterval = 0.5

    private let panel: NSPanel
    private let label: NSTextField
    private let longCompareNoteLabel: NSTextField?
    private let timeRemainingLabel: NSTextField?
    private let indicator: NSProgressIndicator
    private let bucketIndicator: NSProgressIndicator?
    private let cancelButton: FocusableDialogButton
    private let cancelTarget = CancelTarget()
    private var keyboardMonitor: Any?
    private var isClosed = false
    private let isIndeterminateMode: Bool
    private let cancelFlag = CancelFlag()
    private let showsTimeRemainingEstimate: Bool
    private var progressStartDate: Date?
    private var etaTimer: Timer?
    private let etaTimerTarget = ETATimerTarget()
    private let mutedNoteColor: NSColor
    /// Readable from background extraction tasks (CLIP/CNN).
    nonisolated var cancelRequested: Bool { cancelFlag.isCancelled }
    /// Invoked on the main thread when the user cancels (after the cancel flag is set).
    var onCancel: (() -> Void)?

    /// Shown on the second line during long similar-image bucket compares (see `setLongCompareNoteVisible`).
    static let longCompareNoteMessage =
        "Comparison in progress. Progress has not stalled."

    init(
        title: String,
        labelText: String,
        maximum: Int,
        detailText: String? = nil,
        mutedNoteColor: NSColor = .secondaryLabelColor,
        indeterminate: Bool = false,
        showsLongCompareNoteLine: Bool = false,
        showsBucketProgressLine: Bool = false
    ) {
        showsTimeRemainingEstimate = detailText != nil
        isIndeterminateMode = indeterminate
        self.mutedNoteColor = mutedNoteColor
        var panelHeight: CGFloat = detailText == nil ? 120 : (showsTimeRemainingEstimate ? 172 : 156)
        if showsLongCompareNoteLine {
            panelHeight += 22
        }
        if showsBucketProgressLine {
            panelHeight += 22
        }
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: panelHeight),
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

        let timeRemaining: NSTextField?
        if showsTimeRemainingEstimate {
            let eta = NSTextField(labelWithString: "")
            eta.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            eta.textColor = mutedNoteColor
            eta.lineBreakMode = .byTruncatingTail
            eta.maximumNumberOfLines = 1
            eta.translatesAutoresizingMaskIntoConstraints = false
            timeRemaining = eta
        } else {
            timeRemaining = nil
        }
        timeRemainingLabel = timeRemaining

        let longCompareNote: NSTextField?
        if showsLongCompareNoteLine {
            let note = NSTextField(wrappingLabelWithString: Self.longCompareNoteMessage)
            note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            note.textColor = mutedNoteColor
            note.lineBreakMode = .byWordWrapping
            note.maximumNumberOfLines = 2
            note.translatesAutoresizingMaskIntoConstraints = false
            note.isHidden = true
            longCompareNote = note
        } else {
            longCompareNote = nil
        }
        longCompareNoteLabel = longCompareNote

        indicator = NSProgressIndicator()
        indicator.style = .bar
        indicator.isIndeterminate = indeterminate
        indicator.minValue = 0
        if indeterminate {
            indicator.maxValue = 100
        } else {
            indicator.maxValue = Double(max(1, maximum))
        }
        indicator.doubleValue = 0
        indicator.translatesAutoresizingMaskIntoConstraints = false

        let bucketBar: NSProgressIndicator?
        if showsBucketProgressLine {
            let bar = NSProgressIndicator()
            bar.style = .bar
            bar.isIndeterminate = false
            bar.minValue = 0
            bar.maxValue = 1
            bar.doubleValue = 0
            bar.isHidden = true
            bar.translatesAutoresizingMaskIntoConstraints = false
            bucketBar = bar
        } else {
            bucketBar = nil
        }
        bucketIndicator = bucketBar

        let cancelButton = FocusableDialogButton(title: "Cancel", target: cancelTarget, action: #selector(CancelTarget.tapped))
        cancelButton.bezelStyle = .rounded
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        self.cancelButton = cancelButton
        cancelTarget.onCancel = { [weak self] in
            guard let self else { return }
            self.cancelFlag.cancel()
            self.setLabelOnMain("Cancelling…")
            self.onCancel?()
        }

        let content = NSView()
        content.wantsLayer = true
        content.addSubview(label)
        if let longCompareNote {
            content.addSubview(longCompareNote)
        }
        if let timeRemaining {
            content.addSubview(timeRemaining)
        }
        content.addSubview(indicator)
        if let bucketBar {
            content.addSubview(bucketBar)
        }
        content.addSubview(cancelButton)

        let progressTopAnchor: NSLayoutYAxisAnchor
        if let timeRemaining {
            progressTopAnchor = timeRemaining.bottomAnchor
        } else if let longCompareNote {
            progressTopAnchor = longCompareNote.bottomAnchor
        } else {
            progressTopAnchor = label.bottomAnchor
        }
        let progressTopSpacing: CGFloat = (timeRemaining == nil && longCompareNote == nil) ? 10 : 6

        var constraints: [NSLayoutConstraint] = [
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: Self.labelMaxWidth),
            indicator.topAnchor.constraint(equalTo: progressTopAnchor, constant: progressTopSpacing),
            indicator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            indicator.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -12),
            cancelButton.centerYAnchor.constraint(equalTo: indicator.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ]

        if let bucketBar {
            constraints += [
                bucketBar.topAnchor.constraint(equalTo: indicator.bottomAnchor, constant: 8),
                bucketBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                bucketBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            ]
        }

        if let longCompareNote {
            constraints += [
                longCompareNote.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
                longCompareNote.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                longCompareNote.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            ]
        }

        if let timeRemaining {
            let timeTop = longCompareNote?.bottomAnchor ?? label.bottomAnchor
            let timeTopSpacing: CGFloat = longCompareNote == nil ? 4 : 4
            constraints += [
                timeRemaining.topAnchor.constraint(equalTo: timeTop, constant: timeTopSpacing),
                timeRemaining.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                timeRemaining.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
                timeRemaining.heightAnchor.constraint(equalToConstant: 16),
            ]
        }

        let progressBottomAnchor: NSLayoutYAxisAnchor = bucketBar?.bottomAnchor ?? indicator.bottomAnchor

        if let detailText {
            let detail = NSTextField(wrappingLabelWithString: detailText)
            detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            detail.textColor = mutedNoteColor
            detail.lineBreakMode = .byWordWrapping
            detail.maximumNumberOfLines = 0
            detail.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(detail)
            constraints += [
                detail.topAnchor.constraint(equalTo: progressBottomAnchor, constant: 10),
                detail.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                detail.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                detail.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            ]
        } else {
            constraints.append(progressBottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16))
        }

        NSLayoutConstraint.activate(constraints)
        panel.contentView = content
        setLabelOnMain(labelText)
    }

    func show() {
        progressStartDate = Date()
        if showsTimeRemainingEstimate {
            etaTimerTarget.owner = self
            let timer = Timer(
                timeInterval: Self.etaRefreshInterval,
                target: etaTimerTarget,
                selector: #selector(ETATimerTarget.tick),
                userInfo: nil,
                repeats: true
            )
            RunLoop.main.add(timer, forMode: .common)
            etaTimer = timer
        }
        panel.center()
        keyboardMonitor = AppKitDialogKeyboardNavigation.install(
            on: panel,
            buttonsLeftToRight: [cancelButton],
            escapeButton: cancelButton
        )
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(cancelButton)
        if isIndeterminateMode {
            indicator.startAnimation(nil)
        }
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
        etaTimer?.invalidate()
        etaTimer = nil
        progressStartDate = nil
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
        }
        keyboardMonitor = nil
        panel.orderOut(nil)
    }

    nonisolated func setMaximum(_ maximum: Int) {
        Task { @MainActor in
            self.setMaximumOnMain(maximum)
        }
    }

    nonisolated func update(value: Int? = nil, label text: String? = nil) {
        Task { @MainActor in
            self.updateOnMain(value: value, label: text)
        }
    }

    func setLongCompareNoteVisible(_ visible: Bool) {
        guard let longCompareNoteLabel else { return }
        longCompareNoteLabel.stringValue = Self.longCompareNoteMessage
        longCompareNoteLabel.isHidden = !visible
        refreshOnMain()
    }

    func setBucketProgressHidden(_ hidden: Bool) {
        guard let bucketIndicator else { return }
        bucketIndicator.isHidden = hidden
        refreshOnMain()
    }

    nonisolated func updateBucket(value: Int, maximum: Int) {
        Task { @MainActor in
            self.updateBucketOnMain(value: value, maximum: maximum)
        }
    }

    private func updateBucketOnMain(value: Int, maximum: Int) {
        guard !isClosed, let bucketIndicator else { return }
        bucketIndicator.isHidden = false
        bucketIndicator.maxValue = Double(max(1, maximum))
        bucketIndicator.doubleValue = Double(min(max(0, value), maximum))
        refreshOnMain()
    }

    private func setMaximumOnMain(_ maximum: Int) {
        guard !isClosed, !isIndeterminateMode else { return }
        indicator.maxValue = Double(max(1, maximum))
    }

    private func setValueOnMain(_ value: Int) {
        guard !isClosed, !isIndeterminateMode else { return }
        indicator.doubleValue = Double(value)
    }

    private func setLabelOnMain(_ text: String) {
        guard !isClosed else { return }
        label.stringValue = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { RenamePrefixPlanner.elideMiddle(String($0), maxLen: Self.lineMaxChars) }
            .joined(separator: "\n")
    }

    private func updateOnMain(value: Int? = nil, label text: String? = nil) {
        if let value { setValueOnMain(value) }
        if let text { setLabelOnMain(text) }
        refreshOnMain()
    }

    private func refreshTimeRemainingEstimate() {
        guard !isClosed, let timeRemainingLabel, let start = progressStartDate else { return }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed >= Self.etaWarmupSeconds else {
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
        timeRemainingLabel.stringValue = "About \(Self.formatDuration(remaining)) remaining"
        refreshOnMain()
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(1, Int(seconds.rounded()))
        if total < 60 { return "\(total) sec" }
        let minutes = total / 60
        let sec = total % 60
        if minutes < 60 {
            return sec > 0 ? "\(minutes) min \(sec) sec" : "\(minutes) min"
        }
        let hours = minutes / 60
        let remMin = minutes % 60
        return remMin > 0 ? "\(hours) hr \(remMin) min" : "\(hours) hr"
    }

    private func refreshOnMain() {
        guard !isClosed else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
    }

    private func refresh() {
        refreshOnMain()
    }

    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    private final class CancelTarget: NSObject {
        var onCancel: (() -> Void)?

        @objc func tapped() {
            onCancel?()
        }
    }

    private final class ETATimerTarget: NSObject {
        weak var owner: CancellableProgressPanelController?

        @MainActor @objc func tick() {
            owner?.refreshTimeRemainingEstimate()
        }
    }
}
