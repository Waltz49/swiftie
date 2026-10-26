import AppKit
import SwiftUI

@MainActor
struct ActiveJobStripView: View {
    @Environment(AppState.self) private var appState

    var includeQueueJobsRow: Bool = false

    var body: some View {
        let _ = appState.imageGenUIRevision
        let controller = appState.imageGen
        let strip = controller.activeStripView
        ActiveJobStripNSViewRepresentable(
            stripView: strip,
            stripFingerprint: strip.fingerprint(),
            includeQueueJobsRow: includeQueueJobsRow
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .allowsHitTesting(true)
    }
}

@MainActor
final class ActiveJobStripNSView: NSView {
    var onCancel: (() -> Void)?
    var onSkipCooldown: (() -> Void)?
    var onAddSeries: ((Int, Bool) -> Void)?
    var onSubtractSeries: ((Bool) -> Void)?

    private struct BarHandle {
        let prefix: NSTextField
        let postfix: NSTextField
        let bar: StripProgressBarNSView
        let tooltipHost: StripProgressTooltipHostNSView
    }

    private let frameView = NSView()
    private let frameRow = NSStackView()
    private let contentColumn = NSStackView()
    private let rowsStack = NSStackView()
    private let cooldownRow = NSStackView()
    private let iconColumn = NSView()
    private var cooldownSkipView: CooldownSkipNSView?
    private var cancelButton: NSButton?
    private var plusButton: NSAssetIconButton?
    private var minusButton: NSAssetIconButton?
    private var iconColumnWidthConstraint: NSLayoutConstraint?
    private var colors: ThemeColors = .dark
    private var lastStructureKey = ""
    private var lastColorsID = ""
    private var barHandles: [BarHandle] = []
    private var stripProgressTooltipText = ""
    private(set) var cachedContentHeight: CGFloat = 0
    private var contentHeightReportScheduled = false
    private var lastLayoutWidth: CGFloat = 0
    var onContentHeightChanged: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        frameView.wantsLayer = true
        frameView.translatesAutoresizingMaskIntoConstraints = false
        frameRow.orientation = .horizontal
        frameRow.alignment = .centerY
        frameRow.distribution = .fill
        frameRow.spacing = 4
        frameRow.translatesAutoresizingMaskIntoConstraints = false
        contentColumn.setContentHuggingPriority(.defaultLow, for: .horizontal)
        contentColumn.orientation = .vertical
        contentColumn.alignment = .leading
        contentColumn.spacing = 2
        contentColumn.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 2
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        cooldownRow.orientation = .horizontal
        cooldownRow.alignment = .centerY
        cooldownRow.distribution = .fill
        cooldownRow.spacing = 0
        cooldownRow.translatesAutoresizingMaskIntoConstraints = false
        iconColumn.translatesAutoresizingMaskIntoConstraints = false
        iconColumn.isHidden = true
        contentColumn.addArrangedSubview(cooldownRow)
        contentColumn.addArrangedSubview(rowsStack)
        frameRow.addArrangedSubview(contentColumn)
        frameRow.addArrangedSubview(iconColumn)
        frameView.addSubview(frameRow)
        addSubview(frameView)
        let iconWidth = iconColumn.widthAnchor.constraint(equalToConstant: JobQueueLayout.stripIconColumnWidth)
        iconWidth.isActive = true
        iconColumnWidthConstraint = iconWidth
        rowsStack.widthAnchor.constraint(equalTo: contentColumn.widthAnchor).isActive = true
        cooldownRow.widthAnchor.constraint(equalTo: contentColumn.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            frameView.leadingAnchor.constraint(equalTo: leadingAnchor),
            frameView.trailingAnchor.constraint(equalTo: trailingAnchor),
            frameView.topAnchor.constraint(equalTo: topAnchor),
            frameView.bottomAnchor.constraint(equalTo: bottomAnchor),
            frameRow.leadingAnchor.constraint(equalTo: frameView.leadingAnchor, constant: 4),
            frameRow.trailingAnchor.constraint(equalTo: frameView.trailingAnchor, constant: -4),
            frameRow.topAnchor.constraint(equalTo: frameView.topAnchor, constant: 4),
            frameRow.bottomAnchor.constraint(equalTo: frameView.bottomAnchor, constant: -4),
        ])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: max(cachedContentHeight, 28))
    }

    func refreshCachedContentHeight(forWidth width: CGFloat) {
        guard width > 0 else { return }
        layoutSubtreeIfNeeded()
        for handle in barHandles {
            handle.bar.needsDisplay = true
        }
        let measured = max(measuredContentHeight(), 28)
        guard abs(measured - cachedContentHeight) > 1 else { return }
        cachedContentHeight = measured
        invalidateIntrinsicContentSize()
        scheduleContentHeightReport()
    }

    override func layout() {
        super.layout()
        // Live progress only changes bar fill and labels. Remeasure when the width
        // changes so a narrow sidebar does not refit the pane on every tick.
        let width = bounds.width
        guard abs(width - lastLayoutWidth) > 0.5 else { return }
        lastLayoutWidth = width
        refreshCachedContentHeight(forWidth: width)
    }

    private func measuredContentHeight() -> CGFloat {
        var rowsHeight: CGFloat = 0
        for subview in rowsStack.arrangedSubviews {
            let rowH = subview.fittingSize.height
            let floor = max(JobQueueLayout.stripBarHeight, ceil(JobQueueLayout.fontSize * 1.25))
            rowsHeight += rowH > 1 ? rowH : floor
        }
        if rowsHeight > 0, rowsStack.arrangedSubviews.count > 1 {
            rowsHeight += CGFloat(rowsStack.arrangedSubviews.count - 1) * rowsStack.spacing
        }
        let cooldownHeight = cooldownRow.isHidden ? 0 : max(cooldownRow.fittingSize.height, 20)
        let contentHeight = cooldownHeight + rowsHeight
        // Match Python ``_ACTIVE_JOB_STRIP_FRAME_CHROME_V`` (border + inner padding).
        return 10 + max(contentHeight, 18)
    }

    private func scheduleContentHeightReport() {
        guard !contentHeightReportScheduled else { return }
        contentHeightReportScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            contentHeightReportScheduled = false
            onContentHeightChanged?()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyTheme(_ colors: ThemeColors) {
        self.colors = colors
        frameView.layer?.borderWidth = 1
        frameView.layer?.borderColor = NSColor(colors.defaultBorder).cgColor
        frameView.layer?.backgroundColor = NSColor.clear.cgColor
    }

    func update(stripView: ActiveJobStripStatusView, colors: ThemeColors) {
        let structureKey = stripView.structureKey()
        let colorsKey = colors.themeID
        if structureKey == lastStructureKey && colorsKey == lastColorsID {
            updateLiveFields(stripView)
            syncProgressBarTooltips(stripView.progressTooltipText)
            return
        }
        lastStructureKey = structureKey
        lastColorsID = colorsKey
        rebuild(stripView: stripView, colors: colors)
    }

    private func updateLiveFields(_ stripView: ActiveJobStripStatusView) {
        if stripView.mode == "cooldown" {
            if let cooldownSkipView {
                cooldownSkipView.configure(
                    prefix: stripView.cooldownText,
                    count: stripView.cooldownCountText,
                    showSkip: stripView.showSkipIcon
                )
            } else {
                rebuild(stripView: stripView, colors: colors)
            }
            return
        }

        let barRows = stripView.rows.compactMap { row -> ActiveJobStripRowKind? in
            if case .bar = row { return row }
            return nil
        }
        guard barRows.count == barHandles.count else {
            rebuild(stripView: stripView, colors: colors)
            return
        }
        for (handle, row) in zip(barHandles, barRows) {
            guard case .bar(_, let prefix, let postfix, let fillPercent, let slotText, let showPendingStart) = row else {
                continue
            }
            if handle.prefix.stringValue != prefix {
                handle.prefix.stringValue = prefix
            }
            if handle.postfix.stringValue != postfix {
                handle.postfix.stringValue = postfix
            }
            handle.bar.setValues(
                fillPercent: fillPercent,
                slotText: slotText,
                showPendingStart: showPendingStart
            )
        }
        syncProgressBarTooltips(stripView.progressTooltipText)
    }

    private func rebuild(stripView: ActiveJobStripStatusView, colors: ThemeColors) {
        applyTheme(colors)
        stripProgressTooltipText = stripView.progressTooltipText
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        cooldownRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        cooldownSkipView = nil
        barHandles.removeAll()

        for row in stripView.rows {
            switch row {
            case .bar(let label, let prefix, let postfix, let fillPercent, let slotText, let showPendingStart):
                rowsStack.addArrangedSubview(makeBarRow(
                    label: label,
                    prefix: prefix,
                    postfix: postfix,
                    fillPercent: fillPercent,
                    slotText: slotText,
                    showPendingStart: showPendingStart
                ))
            case .count(let label, let count):
                let rowView = NSStackView()
                rowView.orientation = .horizontal
                rowView.spacing = 4
                let lbl = makeLabel(label, muted: true)
                lbl.widthAnchor.constraint(equalToConstant: JobQueueLayout.labelWidth).isActive = true
                let val = makeLabel(count, muted: false)
                rowView.addArrangedSubview(lbl)
                rowView.addArrangedSubview(val)
                rowsStack.addArrangedSubview(rowView)
            }
        }

        if !stripView.cooldownText.isEmpty {
            let skipView = CooldownSkipNSView()
            skipView.applyTheme(colors)
            skipView.configure(
                prefix: stripView.cooldownText,
                count: stripView.cooldownCountText,
                showSkip: stripView.showSkipIcon
            )
            skipView.onSkip = { [weak self] in self?.onSkipCooldown?() }
            skipView.setContentHuggingPriority(.required, for: .horizontal)
            skipView.setContentCompressionResistancePriority(.required, for: .horizontal)
            cooldownSkipView = skipView
            cooldownRow.addArrangedSubview(skipView)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            cooldownRow.addArrangedSubview(spacer)
        } else {
            cooldownSkipView = nil
        }
        cooldownRow.isHidden = cooldownSkipView == nil
        updateIconColumn(show: stripView.showCancelIcon, canAdd: false, canSubtract: false)
        for case let row as NSStackView in rowsStack.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
        cachedContentHeight = 0
        invalidateIntrinsicContentSize()
        let measureWidth = bounds.width > 1 ? bounds.width : 280
        layoutSubtreeIfNeeded()
        refreshCachedContentHeight(forWidth: measureWidth)
        let estimated = JobQueuePaneMetrics.estimatedActiveStripHeight(for: stripView)
        if cachedContentHeight < estimated {
            cachedContentHeight = estimated
            invalidateIntrinsicContentSize()
        }
        scheduleContentHeightReport()
        syncProgressBarTooltips(stripProgressTooltipText)
    }

    private func syncProgressBarTooltips(_ text: String) {
        stripProgressTooltipText = text
        for handle in barHandles {
            handle.tooltipHost.progressTooltipText = text
            handle.tooltipHost.themeColors = colors
        }
    }

    private func makeLabel(_ text: String, muted: Bool) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: JobQueueLayout.fontSize)
        label.textColor = muted ? NSColor(colors.jobQueueMutedText) : NSColor(colors.sidebarText)
        label.isEditable = false
        label.isBezeled = false
        label.drawsBackground = false
        return label
    }

    private func makeBarRow(
        label: String,
        prefix: String,
        postfix: String,
        fillPercent: Int,
        slotText: String,
        showPendingStart: Bool
    ) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        let lbl = makeLabel(label, muted: true)
        lbl.widthAnchor.constraint(equalToConstant: JobQueueLayout.labelWidth).isActive = true
        row.addArrangedSubview(lbl)

        let pre = makeLabel(prefix, muted: false)
        pre.widthAnchor.constraint(equalToConstant: 40).isActive = true
        row.addArrangedSubview(pre)

        let bar = StripProgressBarNSView()
        bar.applyTheme(colors)
        bar.setValues(fillPercent: fillPercent, slotText: slotText, showPendingStart: showPendingStart)
        bar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: JobQueueLayout.stripBarHeight).isActive = true
        bar.widthAnchor.constraint(greaterThanOrEqualToConstant: JobQueueLayout.stripBarMinWidth).isActive = true
        row.addArrangedSubview(bar)

        let post = makeLabel(postfix, muted: false)
        post.widthAnchor.constraint(equalToConstant: 48).isActive = true
        row.addArrangedSubview(post)

        let tooltipHost = StripProgressTooltipHostNSView()
        tooltipHost.progressTooltipText = stripProgressTooltipText
        tooltipHost.themeColors = colors
        tooltipHost.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(row)
        container.addSubview(tooltipHost)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            row.topAnchor.constraint(equalTo: container.topAnchor),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            tooltipHost.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tooltipHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tooltipHost.topAnchor.constraint(equalTo: container.topAnchor),
            tooltipHost.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        barHandles.append(BarHandle(prefix: pre, postfix: post, bar: bar, tooltipHost: tooltipHost))
        return container
    }

    func updateSeriesControls(canAdd: Bool, canSubtract: Bool) {
        plusButton?.isEnabled = canAdd
        minusButton?.isEnabled = canSubtract
    }

    private func updateIconColumn(show: Bool, canAdd: Bool, canSubtract: Bool) {
        iconColumn.subviews.forEach { $0.removeFromSuperview() }
        cancelButton = nil
        plusButton = nil
        minusButton = nil
        iconColumn.isHidden = !show
        guard show else { return }

        let column = NSStackView()
        column.orientation = .vertical
        column.spacing = 2
        column.alignment = .centerX
        column.translatesAutoresizingMaskIntoConstraints = false

        let seriesRow = NSStackView()
        seriesRow.orientation = .horizontal
        seriesRow.spacing = 4
        seriesRow.alignment = .centerY
        let plus = makeSeriesPlusButton()
        let minus = makeSeriesMinusButton()
        plus.isEnabled = canAdd
        minus.isEnabled = canSubtract
        plusButton = plus
        minusButton = minus
        seriesRow.addArrangedSubview(plus)
        seriesRow.addArrangedSubview(minus)

        let trash = makeCancelIconButton()
        cancelButton = trash

        column.addArrangedSubview(seriesRow)
        column.addArrangedSubview(trash)

        iconColumn.addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: iconColumn.centerXAnchor),
            column.centerYAnchor.constraint(equalTo: iconColumn.centerYAnchor),
        ])
    }

    private func makeStripIconButton(
        normalName: String,
        hoverName: String,
        tooltip: String,
        action: Selector
    ) -> NSAssetIconButton {
        let button = NSAssetIconButton(
            normalName: normalName,
            hoverName: hoverName,
            size: JobQueueLayout.stripIconSize,
            tooltip: tooltip
        )
        button.target = self
        button.action = action
        return button
    }

    private func makeSeriesPlusButton() -> NSAssetIconButton {
        makeStripIconButton(
            normalName: "series_plus_icon",
            hoverName: "series_plus_icon_hover",
            tooltip: """
            Add another image to this series
            Option+click to set copies to 51 (runs continuously).
            """,
            action: #selector(addSeriesAction)
        )
    }

    private func makeSeriesMinusButton() -> NSAssetIconButton {
        makeStripIconButton(
            normalName: "series_minus_icon",
            hoverName: "series_minus_icon_hover",
            tooltip: """
            Remove one pending image from the series.
            Option+click to remove all remaining images.
            """,
            action: #selector(subtractSeriesAction)
        )
    }

    private func makeCancelIconButton() -> NSButton {
        makeStripIconButton(
            normalName: "trash_icon",
            hoverName: "trash_icon_hover",
            tooltip: "Cancel generation",
            action: #selector(cancelAction)
        )
    }

    @objc private func cancelAction() { onCancel?() }
    @objc private func addSeriesAction() {
        onAddSeries?(1, NSEvent.modifierFlags.contains(.option))
    }
    @objc private func subtractSeriesAction() {
        onSubtractSeries?(NSEvent.modifierFlags.contains(.option))
    }
}

struct ActiveJobStripNSViewRepresentable: NSViewRepresentable {
    @Environment(AppState.self) private var appState
    var stripView: ActiveJobStripStatusView
    var stripFingerprint: String
    var includeQueueJobsRow: Bool = false

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ActiveJobStripNSView, context: Context) -> CGSize? {
        let width = resolvedLayoutWidth(proposal: proposal, nsView: nsView)
        nsView.refreshCachedContentHeight(forWidth: width)
        let height = max(nsView.cachedContentHeight, 28)
        return CGSize(width: width, height: height)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ActiveJobStripNSView {
        let view = ActiveJobStripNSView()
        wireStripActions(on: view, appState: appState)
        installCallbacks(on: view, context: context)
        return view
    }

    func updateNSView(_ nsView: ActiveJobStripNSView, context: Context) {
        installCallbacks(on: nsView, context: context)
        wireStripActions(on: nsView, appState: appState)
        // Read the controller so a deferred SwiftUI pass cannot paint a stale bar
        // over an in-place progress tick.
        nsView.update(stripView: appState.imageGen.activeStripView, colors: appState.theme.colors)
        applySeriesControlState(to: nsView, appState: appState)
    }

    static func dismantleNSView(_ nsView: ActiveJobStripNSView, coordinator: Coordinator) {
        if let id = coordinator.sinkID {
            coordinator.controller?.setStripLiveSink(id, nil)
        }
        coordinator.sinkID = nil
        coordinator.controller = nil
    }

    @MainActor
    private func wireStripActions(on nsView: ActiveJobStripNSView, appState: AppState) {
        nsView.onCancel = { appState.confirmCancelGeneration() }
        nsView.onSkipCooldown = { appState.imageGen.skipCopyCooldown() }
        nsView.onAddSeries = { delta, option in
            guard let jobID = appState.imageGen.activeJobID else { return }
            if option {
                appState.imageGen.setSeriesContinuous(forJobID: jobID)
            } else {
                appState.imageGen.addSeriesCycle(forJobID: jobID, delta: delta)
            }
        }
        nsView.onSubtractSeries = { removeAll in
            guard let jobID = appState.imageGen.activeJobID else { return }
            appState.imageGen.subtractSeriesRemaining(forJobID: jobID, removeAll: removeAll)
        }
    }

    @MainActor
    private func applySeriesControlState(to nsView: ActiveJobStripNSView, appState: AppState) {
        guard let jobID = appState.imageGen.activeJobID else {
            nsView.updateSeriesControls(canAdd: false, canSubtract: false)
            return
        }
        let state = appState.imageGen.actionBarState(for: jobID)
        nsView.updateSeriesControls(canAdd: state.canAddSeries, canSubtract: state.canSubtractSeries)
    }

    @MainActor
    private func installCallbacks(on nsView: ActiveJobStripNSView, context: Context) {
        nsView.onContentHeightChanged = { [weak nsView] in
            guard let nsView else { return }
            reportMeasuredHeight(nsView: nsView, appState: appState)
        }
        appState.jobsQueueStripMeasureRefresh = { [weak nsView] in
            guard let nsView else { return }
            let width = max(nsView.bounds.width, 280)
            nsView.refreshCachedContentHeight(forWidth: width)
            reportMeasuredHeight(nsView: nsView, appState: appState)
        }
        let id = ObjectIdentifier(nsView)
        context.coordinator.sinkID = id
        context.coordinator.controller = appState.imageGen
        appState.imageGen.setStripLiveSink(id) { [weak nsView, weak appState] strip in
            guard let nsView, let appState else { return }
            let before = nsView.cachedContentHeight
            nsView.update(stripView: strip, colors: appState.theme.colors)
            applySeriesControlState(to: nsView, appState: appState)
            guard abs(nsView.cachedContentHeight - before) > 1 else { return }
            let estimated = JobQueuePaneMetrics.estimatedActiveStripHeight(for: strip)
            appState.updateMeasuredActiveJobStripHeight(max(nsView.cachedContentHeight, estimated, 28))
        }
    }

    final class Coordinator {
        var sinkID: ObjectIdentifier?
        weak var controller: ImageGenController?
    }

    private func resolvedLayoutWidth(
        proposal: ProposedViewSize?,
        nsView: ActiveJobStripNSView
    ) -> CGFloat {
        if let proposalWidth = proposal?.width, proposalWidth > 1 { return proposalWidth }
        if nsView.bounds.width > 1 { return nsView.bounds.width }
        return 1
    }

    @MainActor
    private func reportMeasuredHeight(nsView: ActiveJobStripNSView, appState: AppState) {
        let width = max(nsView.bounds.width, 1)
        nsView.refreshCachedContentHeight(forWidth: width)
        let estimated = JobQueuePaneMetrics.estimatedActiveStripHeight(for: appState.imageGen.activeStripView)
        appState.updateMeasuredActiveJobStripHeight(max(nsView.cachedContentHeight, estimated, 28))
    }
}
