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
    }
}

@MainActor
final class ActiveJobStripNSView: NSView {
    var onCancel: (() -> Void)?
    var onSkipCooldown: (() -> Void)?

    private struct BarHandle {
        let prefix: NSTextField
        let postfix: NSTextField
        let bar: StripProgressBarNSView
    }

    private let frameView = NSView()
    private let frameRow = NSStackView()
    private let contentColumn = NSStackView()
    private let rowsStack = NSStackView()
    private let cooldownRow = NSStackView()
    private let iconColumn = NSView()
    private var cooldownSkipView: CooldownSkipNSView?
    private var cancelButton: NSButton?
    private var colors: ThemeColors = .dark
    private var lastStructureKey = ""
    private var lastColorsID = ""
    private var barHandles: [BarHandle] = []
    private(set) var cachedContentHeight: CGFloat = 0
    private var contentHeightReportScheduled = false
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
        iconColumn.widthAnchor.constraint(equalToConstant: JobQueueLayout.actionButtonSize).isActive = true
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
        refreshCachedContentHeight(forWidth: bounds.width)
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
            handle.prefix.stringValue = prefix
            handle.postfix.stringValue = postfix
            handle.bar.setValues(
                fillPercent: fillPercent,
                slotText: slotText,
                showPendingStart: showPendingStart
            )
        }
    }

    private func rebuild(stripView: ActiveJobStripStatusView, colors: ThemeColors) {
        applyTheme(colors)
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
        updateCancelButton(show: stripView.showCancelIcon)
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
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 4
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

        barHandles.append(BarHandle(prefix: pre, postfix: post, bar: bar))
        return row
    }

    private func updateCancelButton(show: Bool) {
        cancelButton?.removeFromSuperview()
        cancelButton = nil
        iconColumn.isHidden = !show
        guard show else { return }
        let button = makeCancelIconButton()
        cancelButton = button
        iconColumn.addSubview(button)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: iconColumn.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: iconColumn.centerYAnchor),
        ])
    }

    private func makeCancelIconButton() -> NSButton {
        let button = NSAssetIconButton(
            normalName: "trash_icon",
            hoverName: "trash_icon_hover",
            size: 16,
            tooltip: "Cancel generation"
        )
        button.target = self
        button.action = #selector(cancelAction)
        return button
    }

    @objc private func cancelAction() { onCancel?() }
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

    func makeNSView(context: Context) -> ActiveJobStripNSView {
        let view = ActiveJobStripNSView()
        view.onCancel = { appState.confirmCancelGeneration() }
        view.onSkipCooldown = { appState.imageGen.skipCopyCooldown() }
        view.onContentHeightChanged = { [weak view] in
            guard let view else { return }
            reportMeasuredHeight(nsView: view, appState: appState)
        }
        appState.jobsQueueStripMeasureRefresh = { [weak view] in
            guard let view else { return }
            let width = max(view.bounds.width, 280)
            view.refreshCachedContentHeight(forWidth: width)
            reportMeasuredHeight(nsView: view, appState: appState)
        }
        return view
    }

    func updateNSView(_ nsView: ActiveJobStripNSView, context: Context) {
        let colors = appState.theme.colors
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
        nsView.update(stripView: stripView, colors: colors)
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
