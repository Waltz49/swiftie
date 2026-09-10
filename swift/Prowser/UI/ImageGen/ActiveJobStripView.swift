import AppKit
import SwiftUI

@MainActor
struct ActiveJobStripView: View {
    @Environment(AppState.self) private var appState

    var includeQueueJobsRow: Bool = false

    var body: some View {
        let _ = appState.imageGen.queueRevision
        ActiveJobStripNSViewRepresentable(includeQueueJobsRow: includeQueueJobsRow)
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
    private let rowsStack = NSStackView()
    private let cooldownRow = NSStackView()
    private var colors: ThemeColors = .dark
    private var lastStructureKey = ""
    private var lastColorsID = ""
    private var barHandles: [BarHandle] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        frameView.wantsLayer = true
        frameView.clipsToBounds = true
        frameView.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.orientation = .vertical
        rowsStack.alignment = .width
        rowsStack.spacing = 2
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        cooldownRow.orientation = .horizontal
        cooldownRow.spacing = 4
        cooldownRow.translatesAutoresizingMaskIntoConstraints = false
        frameView.addSubview(rowsStack)
        frameView.addSubview(cooldownRow)
        addSubview(frameView)
        NSLayoutConstraint.activate([
            frameView.leadingAnchor.constraint(equalTo: leadingAnchor),
            frameView.trailingAnchor.constraint(equalTo: trailingAnchor),
            frameView.topAnchor.constraint(equalTo: topAnchor),
            frameView.bottomAnchor.constraint(equalTo: bottomAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: frameView.leadingAnchor, constant: 4),
            rowsStack.trailingAnchor.constraint(equalTo: frameView.trailingAnchor, constant: -4),
            rowsStack.topAnchor.constraint(equalTo: frameView.topAnchor, constant: 4),
            cooldownRow.leadingAnchor.constraint(equalTo: frameView.leadingAnchor, constant: 4),
            cooldownRow.trailingAnchor.constraint(lessThanOrEqualTo: frameView.trailingAnchor, constant: -4),
            cooldownRow.topAnchor.constraint(equalTo: rowsStack.bottomAnchor, constant: 2),
            cooldownRow.bottomAnchor.constraint(equalTo: frameView.bottomAnchor, constant: -4),
        ])
    }

    override var intrinsicContentSize: NSSize {
        layoutSubtreeIfNeeded()
        let rowsHeight = rowsStack.fittingSize.height
        let cooldownHeight = cooldownRow.arrangedSubviews.isEmpty ? 0 : cooldownRow.fittingSize.height + 2
        let height = 8 + rowsHeight + cooldownHeight
        return NSSize(width: NSView.noIntrinsicMetric, height: max(height, 28))
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
        invalidateIntrinsicContentSize()
    }

    private func rebuild(stripView: ActiveJobStripStatusView, colors: ThemeColors) {
        applyTheme(colors)
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        cooldownRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
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
                    showPendingStart: showPendingStart,
                    showCancel: stripView.showCancelIcon
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
            cooldownRow.addArrangedSubview(makeLabel(stripView.cooldownText, muted: true))
            cooldownRow.addArrangedSubview(makeLabel(stripView.cooldownCountText, muted: false))
            if stripView.showSkipIcon {
                cooldownRow.addArrangedSubview(makeIconButton(symbol: "forward.end", action: #selector(skipAction)))
            }
            if stripView.showCancelIcon {
                cooldownRow.addArrangedSubview(makeIconButton(symbol: "trash", action: #selector(cancelAction)))
            }
        }
        cooldownRow.isHidden = cooldownRow.arrangedSubviews.isEmpty
        for case let row as NSStackView in rowsStack.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
        invalidateIntrinsicContentSize()
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
        showPendingStart: Bool,
        showCancel: Bool
    ) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
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

        if showCancel {
            row.addArrangedSubview(makeIconButton(symbol: "trash", action: #selector(cancelAction)))
        }
        barHandles.append(BarHandle(prefix: pre, postfix: post, bar: bar))
        return row
    }

    private func makeIconButton(symbol: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(), target: self, action: action)
        button.bezelStyle = .shadowlessSquare
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 16).isActive = true
        button.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return button
    }

    @objc private func cancelAction() { onCancel?() }
    @objc private func skipAction() { onSkipCooldown?() }
}

struct ActiveJobStripNSViewRepresentable: NSViewRepresentable {
    @Environment(AppState.self) private var appState
    var includeQueueJobsRow: Bool = false

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ActiveJobStripNSView, context: Context) -> CGSize? {
        let width = proposal.width ?? max(nsView.bounds.width, 200)
        nsView.frame.size.width = width
        nsView.layoutSubtreeIfNeeded()
        let height = nsView.intrinsicContentSize.height
        return CGSize(width: width, height: height)
    }

    func makeNSView(context: Context) -> ActiveJobStripNSView {
        let view = ActiveJobStripNSView()
        view.onCancel = { appState.imageGen.cancelActiveJob() }
        view.onSkipCooldown = { appState.imageGen.skipCopyCooldown() }
        return view
    }

    func updateNSView(_ nsView: ActiveJobStripNSView, context: Context) {
        let controller = appState.imageGen
        let colors = appState.theme.colors
        nsView.update(stripView: controller.activeStripView, colors: colors)
        Task {
            await controller.refreshActiveStripView(includeQueueJobsRow: includeQueueJobsRow)
            nsView.update(stripView: controller.activeStripView, colors: colors)
        }
    }
}
