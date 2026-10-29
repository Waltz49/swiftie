import AppKit

/// Determinate progress panel with Cancel (port of Python `QProgressDialog` with cancel for resize batch).
@MainActor
final class CancellableProgressPanelController {
    private static let lineMaxChars = 64
    private static let labelMaxWidth: CGFloat = 400

    private let panel: NSPanel
    private let label: NSTextField
    private let longCompareNoteLabel: NSTextField?
    private let timeRemainingLabel: NSTextField?
    private let indicator: NSProgressIndicator
    private let bucketIndicator: NSProgressIndicator?
    private let cancelButton: FocusableDialogButton
    private let cancelTarget = CancelTarget()
    private let accessoryButton: FocusableDialogButton?
    private let accessoryTarget = AccessoryTarget()
    private var keyboardMonitor: Any?
    private var isClosed = false
    private let isIndeterminateMode: Bool
    private let cancelFlag = CancelFlag()
    private let showsTimeRemainingEstimate: Bool
    private let usesExtractionBasedTimeEstimate: Bool
    private var progressStartDate: Date?
    private var etaTimer: Timer?
    private let etaTimerTarget = ETATimerTarget()
    private let minimumProgressUpdateInterval: TimeInterval?
    private var pendingProgressValue: Int?
    private var pendingProgressLabel: String?
    private var pendingBucketValue: Int?
    private var pendingBucketMaximum: Int?
    private var lastProgressUIEmitDate: Date?
    private var lastBucketUIEmitDate: Date?
    private var progressFlushTimer: Timer?
    private let progressFlushTimerTarget = ProgressFlushTimerTarget()
    private let extractionTimeEstimator = ExtractionTimeEstimator()
    private let mutedNoteColor: NSColor
    /// Readable from background extraction tasks (CLIP/CNN).
    nonisolated var cancelRequested: Bool { cancelFlag.isCancelled }
    /// Invoked on the main thread when the user cancels (after the cancel flag is set).
    var onCancel: (() -> Void)?
    /// Optional leading action (e.g. Test LoRAs “Work directory”).
    var onAccessory: (() -> Void)?

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
        showsBucketProgressLine: Bool = false,
        showsTimeRemainingEstimate: Bool? = nil,
        usesExtractionBasedTimeEstimate: Bool = false,
        minimumProgressUpdateInterval: TimeInterval = ProgressDialogTiming.progressUpdateInterval,
        throttleProgressUpdates: Bool = true,
        accessoryButtonTitle: String? = nil,
        promptAccessoryText: String? = nil
    ) {
        let showETA = showsTimeRemainingEstimate ?? (detailText != nil)
        self.showsTimeRemainingEstimate = showETA
        self.usesExtractionBasedTimeEstimate = usesExtractionBasedTimeEstimate
        self.minimumProgressUpdateInterval = throttleProgressUpdates ? minimumProgressUpdateInterval : nil
        isIndeterminateMode = indeterminate
        self.mutedNoteColor = mutedNoteColor
        var panelHeight: CGFloat = 120
        if detailText != nil {
            panelHeight = showETA ? 172 : 156
        } else if showETA {
            panelHeight = 156
        }
        if showsLongCompareNoteLine {
            panelHeight += 22
        }
        if showsBucketProgressLine {
            panelHeight += 22
        }
        if accessoryButtonTitle != nil {
            panelHeight += 36
        }
        let trimmedPromptAccessory = promptAccessoryText?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let promptAccessory: JobQueuePromptAccessoryNSView?
        if !trimmedPromptAccessory.isEmpty {
            promptAccessory = JobQueuePromptAccessoryNSView(prompt: trimmedPromptAccessory)
            panelHeight += JobQueuePromptAccessoryNSView.preferredScrollHeight + 12
        } else {
            promptAccessory = nil
        }
        let panelWidth: CGFloat = promptAccessory == nil ? 440 : 480
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
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
        label.maximumNumberOfLines = promptAccessory == nil ? 3 : 14
        label.translatesAutoresizingMaskIntoConstraints = false

        let timeRemaining: NSTextField?
        if showETA {
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

        let accessoryButton: FocusableDialogButton?
        if let accessoryButtonTitle {
            let button = FocusableDialogButton(
                title: accessoryButtonTitle,
                target: accessoryTarget,
                action: #selector(AccessoryTarget.tapped)
            )
            button.bezelStyle = .rounded
            button.translatesAutoresizingMaskIntoConstraints = false
            button.isEnabled = false
            accessoryButton = button
        } else {
            accessoryButton = nil
        }
        self.accessoryButton = accessoryButton
        cancelTarget.onCancel = { [weak self] in
            guard let self else { return }
            self.cancelFlag.cancel()
            self.setLabelOnMain("Cancelling…")
            self.onCancel?()
        }
        accessoryTarget.onTapped = { [weak self] in
            self?.onAccessory?()
        }

        let content = NSView()
        content.wantsLayer = true
        content.addSubview(label)
        if let promptAccessory {
            content.addSubview(promptAccessory)
        }
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
        if let accessoryButton {
            content.addSubview(accessoryButton)
        }

        let anchorBelowLabel: NSLayoutYAxisAnchor = longCompareNote?.bottomAnchor ?? label.bottomAnchor
        let anchorBelowPromptOrLabel: NSLayoutYAxisAnchor =
            promptAccessory?.bottomAnchor ?? anchorBelowLabel

        let progressTopAnchor: NSLayoutYAxisAnchor
        if let timeRemaining {
            progressTopAnchor = timeRemaining.bottomAnchor
        } else if promptAccessory != nil {
            progressTopAnchor = anchorBelowPromptOrLabel
        } else if let longCompareNote {
            progressTopAnchor = longCompareNote.bottomAnchor
        } else {
            progressTopAnchor = label.bottomAnchor
        }
        let progressTopSpacing: CGFloat = (timeRemaining == nil && longCompareNote == nil && promptAccessory == nil) ? 10 : 6

        var constraints: [NSLayoutConstraint] = [
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: Self.labelMaxWidth),
            indicator.topAnchor.constraint(equalTo: progressTopAnchor, constant: progressTopSpacing),
            indicator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
        ]
        if accessoryButton != nil {
            constraints.append(
                indicator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20)
            )
        } else {
            constraints += [
                indicator.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -12),
                cancelButton.centerYAnchor.constraint(equalTo: indicator.centerYAnchor),
                cancelButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            ]
        }

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

        if let promptAccessory {
            constraints += [
                promptAccessory.topAnchor.constraint(equalTo: anchorBelowLabel, constant: 8),
                promptAccessory.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                promptAccessory.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            ]
        }

        if let timeRemaining {
            let timeTopSpacing: CGFloat = 8
            constraints += [
                timeRemaining.topAnchor.constraint(equalTo: anchorBelowPromptOrLabel, constant: timeTopSpacing),
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
        } else if let accessoryButton {
            constraints += [
                accessoryButton.topAnchor.constraint(equalTo: progressBottomAnchor, constant: 12),
                accessoryButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                cancelButton.topAnchor.constraint(equalTo: progressBottomAnchor, constant: 12),
                cancelButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                accessoryButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
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
            startETATimer()
        }
        if minimumProgressUpdateInterval != nil {
            startProgressFlushTimerIfNeeded()
        }
        panel.center()
        var dialogButtons: [NSButton] = [cancelButton]
        if let accessoryButton {
            dialogButtons.insert(accessoryButton, at: 0)
        }
        keyboardMonitor = AppKitDialogKeyboardNavigation.install(
            on: panel,
            buttonsLeftToRight: dialogButtons,
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
        if pendingProgressValue != nil || pendingProgressLabel != nil || pendingBucketValue != nil {
            flushPendingProgressOnMain()
        }
        isClosed = true
        cancelTarget.onCancel = nil
        accessoryTarget.onTapped = nil
        onCancel = nil
        onAccessory = nil
        etaTimerTarget.owner = nil
        progressFlushTimerTarget.owner = nil
        etaTimer?.invalidate()
        etaTimer = nil
        progressFlushTimer?.invalidate()
        progressFlushTimer = nil
        progressStartDate = nil
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
        }
        keyboardMonitor = nil
        panel.orderOut(nil)
        BrowserWindowIdentity.restoreBrowserKeyAfterAuxiliaryDialog()
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

    /// Status text that must appear immediately (verify/unpack phases), not subject to the 1 Hz throttle.
    nonisolated func updateStatus(label text: String) {
        Task { @MainActor in
            self.setLabelOnMain(text)
            self.refreshOnMain()
        }
    }

    func setAccessoryButtonEnabled(_ enabled: Bool) {
        accessoryButton?.isEnabled = enabled
    }

    /// Switch to an indeterminate bar after feature extraction (sorting / thumbnail rebuild).
    nonisolated func beginIndeterminatePhase(label: String) {
        Task { @MainActor in
            self.beginIndeterminatePhaseOnMain(label: label)
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

    /// Images still needing face extraction (for extraction-based ETA on Cache Faces).
    nonisolated func setRemainingExtractionsForEstimate(_ count: Int) {
        extractionTimeEstimator.setRemaining(count)
    }

    /// Record one face-encoding duration (seconds); keeps the last 100 samples.
    nonisolated func recordExtractionDuration(_ seconds: TimeInterval) {
        extractionTimeEstimator.record(seconds)
    }

    private func updateBucketOnMain(value: Int, maximum: Int) {
        guard !isClosed, bucketIndicator != nil else { return }
        pendingBucketValue = value
        pendingBucketMaximum = maximum

        guard let interval = minimumProgressUpdateInterval else {
            applyPendingBucketOnMain()
            return
        }

        let forceImmediate = shouldFlushBucketImmediately(value: value, maximum: maximum, interval: interval)
        if forceImmediate {
            applyPendingBucketOnMain()
            lastBucketUIEmitDate = Date()
            return
        }
        startProgressFlushTimerIfNeeded()
    }

    private func shouldFlushBucketImmediately(value: Int, maximum: Int, interval: TimeInterval) -> Bool {
        if value >= maximum, maximum > 0 { return true }
        guard let last = lastBucketUIEmitDate else { return true }
        return Date().timeIntervalSince(last) >= interval
    }

    private func applyPendingBucketOnMain() {
        guard let bucketIndicator else { return }
        guard let value = pendingBucketValue, let maximum = pendingBucketMaximum else { return }
        pendingBucketValue = nil
        pendingBucketMaximum = nil
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
        if let value { pendingProgressValue = value }
        if let text { pendingProgressLabel = text }

        guard let interval = minimumProgressUpdateInterval else {
            applyPendingProgressOnMain()
            return
        }

        let forceImmediate = shouldFlushProgressImmediately(value: value, interval: interval)
        if forceImmediate {
            flushPendingProgressOnMain()
            return
        }
        startProgressFlushTimerIfNeeded()
    }

    private func shouldFlushProgressImmediately(value: Int?, interval: TimeInterval) -> Bool {
        let effectiveValue = value ?? pendingProgressValue
        if let effectiveValue, !isIndeterminateMode, effectiveValue >= Int(indicator.maxValue.rounded()) {
            return true
        }
        guard let last = lastProgressUIEmitDate else { return true }
        return Date().timeIntervalSince(last) >= interval
    }

    private func applyPendingProgressOnMain() {
        if let value = pendingProgressValue {
            setValueOnMain(value)
            pendingProgressValue = nil
        }
        if let text = pendingProgressLabel {
            setLabelOnMain(text)
            pendingProgressLabel = nil
        }
        if pendingBucketValue != nil {
            if let interval = minimumProgressUpdateInterval {
                if shouldFlushBucketImmediately(
                    value: pendingBucketValue ?? 0,
                    maximum: pendingBucketMaximum ?? 1,
                    interval: interval
                ) {
                    applyPendingBucketOnMain()
                    lastBucketUIEmitDate = Date()
                }
            } else {
                applyPendingBucketOnMain()
            }
        }
        refreshOnMain()
    }

    private func flushPendingProgressOnMain() {
        applyPendingProgressOnMain()
        lastProgressUIEmitDate = Date()
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

    private func startProgressFlushTimerIfNeeded() {
        guard minimumProgressUpdateInterval != nil, progressFlushTimer == nil else { return }
        progressFlushTimerTarget.owner = self
        let timer = Timer(
            timeInterval: minimumProgressUpdateInterval ?? ProgressDialogTiming.progressUpdateInterval,
            target: progressFlushTimerTarget,
            selector: #selector(ProgressFlushTimerTarget.tick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        progressFlushTimer = timer
    }

    private func flushPendingProgressIfDue() {
        guard !isClosed, minimumProgressUpdateInterval != nil else { return }
        guard pendingProgressValue != nil || pendingProgressLabel != nil || pendingBucketValue != nil else { return }
        let interval = minimumProgressUpdateInterval ?? ProgressDialogTiming.progressUpdateInterval
        let hasMainPending = pendingProgressValue != nil || pendingProgressLabel != nil
        let flushMain = hasMainPending
            && shouldFlushProgressImmediately(value: pendingProgressValue, interval: interval)
        let flushBucket = pendingBucketValue != nil
            && shouldFlushBucketImmediately(
                value: pendingBucketValue ?? 0,
                maximum: pendingBucketMaximum ?? 1,
                interval: interval
            )
        if flushMain {
            flushPendingProgressOnMain()
        } else if flushBucket {
            applyPendingBucketOnMain()
            lastBucketUIEmitDate = Date()
            refreshOnMain()
        }
    }

    private func beginIndeterminatePhaseOnMain(label: String) {
        guard !isClosed else { return }
        indicator.isIndeterminate = true
        indicator.startAnimation(nil)
        progressStartDate = nil
        timeRemainingLabel?.stringValue = ""
        setLabelOnMain(label)
        refreshOnMain()
    }

    private func refreshTimeRemainingEstimate() {
        guard !isClosed, let timeRemainingLabel, let start = progressStartDate else { return }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed >= ProgressDialogTiming.estimateWarmupInterval else {
            timeRemainingLabel.stringValue = ""
            return
        }
        let remaining: TimeInterval?
        if usesExtractionBasedTimeEstimate {
            remaining = extractionTimeEstimator.estimatedSecondsRemaining()
        } else {
            let completed = indicator.doubleValue
            let total = indicator.maxValue
            guard completed > 0, total > completed else {
                timeRemainingLabel.stringValue = ""
                return
            }
            remaining = (elapsed / completed) * (total - completed)
        }
        guard let remaining, remaining > 0 else {
            timeRemainingLabel.stringValue = ""
            return
        }
        timeRemainingLabel.stringValue =
            "About \(ProgressDialogTiming.formatRemainingDuration(remaining)) remaining"
        refreshOnMain()
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

    private final class AccessoryTarget: NSObject {
        var onTapped: (() -> Void)?

        @objc func tapped() {
            onTapped?()
        }
    }

    private final class ETATimerTarget: NSObject {
        weak var owner: CancellableProgressPanelController?

        @MainActor @objc func tick() {
            owner?.refreshTimeRemainingEstimate()
        }
    }

    private final class ProgressFlushTimerTarget: NSObject {
        weak var owner: CancellableProgressPanelController?

        @MainActor @objc func tick() {
            owner?.flushPendingProgressIfDue()
        }
    }

    private final class ExtractionTimeEstimator: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [TimeInterval] = []
        private var extractionsRemaining = 0
        private static let maxSamples = 100

        func setRemaining(_ count: Int) {
            lock.lock()
            extractionsRemaining = max(0, count)
            lock.unlock()
        }

        func record(_ duration: TimeInterval) {
            lock.lock()
            samples.append(duration)
            if samples.count > Self.maxSamples {
                samples.removeFirst(samples.count - Self.maxSamples)
            }
            if extractionsRemaining > 0 {
                extractionsRemaining -= 1
            }
            lock.unlock()
        }

        func estimatedSecondsRemaining() -> TimeInterval? {
            lock.lock()
            defer { lock.unlock() }
            guard extractionsRemaining > 0, !samples.isEmpty else { return nil }
            let avg = samples.reduce(0, +) / Double(samples.count)
            return avg * Double(extractionsRemaining)
        }
    }
}
