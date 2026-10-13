import AppKit

/// Native status block for job queue cards.
/// Port of `imagegen_plugins/job_card_status_widget.py`.
@MainActor
final class JobCardStatusNSView: NSView {
    override var isFlipped: Bool { true }

    private var colors: ThemeColors = .dark
    private var contentWidth: CGFloat = 0
    private var lastFingerprint = ""
    private let rowsStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowsStack)
        NSLayoutConstraint.activate([
            rowsStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: topAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyTheme(_ colors: ThemeColors) {
        self.colors = colors
        lastFingerprint = ""
        if contentWidth > 0 {
            relayoutExistingRows()
        }
    }

    func setContentWidth(_ width: CGFloat) {
        let w = max(80, width)
        guard w != contentWidth else { return }
        contentWidth = w
        lastFingerprint = ""
        relayoutExistingRows()
    }

    func discardRenderedFingerprint() {
        lastFingerprint = ""
    }

    func hasRenderedView() -> Bool {
        !rowsStack.arrangedSubviews.isEmpty
    }

    func setStatusView(_ view: QueueJobStatusView?, contentWidth width: CGFloat) {
        let w = max(80, width)
        contentWidth = w
        guard let view, !view.isEmpty else {
            rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            lastFingerprint = ""
            invalidateIntrinsicContentSize()
            return
        }
        let fingerprint = "\(w)|\(view.fingerprint())"
        if fingerprint == lastFingerprint, !rowsStack.arrangedSubviews.isEmpty {
            return
        }
        lastFingerprint = fingerprint
        rebuild(view: view, width: w)
    }

    private func relayoutExistingRows() {
        guard contentWidth > 0, !rowsStack.arrangedSubviews.isEmpty else { return }
        for row in rowsStack.arrangedSubviews {
            row.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        }
        invalidateIntrinsicContentSize()
    }

    private func rebuild(view: QueueJobStatusView, width: CGFloat) {
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let valueWidth = max(40, width - JobQueueLayout.labelWidth - 2)

        for row in view.rows {
            switch row {
            case .title(let title, let rowRunning):
                let display = (rowRunning || view.running) ? "\(title) (Running)" : title
                let field = makeLabel(display, muted: false, bold: true)
                field.alignment = .center
                field.lineBreakMode = .byTruncatingTail
                let wrap = NSView()
                wrap.translatesAutoresizingMaskIntoConstraints = false
                field.translatesAutoresizingMaskIntoConstraints = false
                wrap.addSubview(field)
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
                    field.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
                    field.topAnchor.constraint(equalTo: wrap.topAnchor),
                    field.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
                    wrap.widthAnchor.constraint(equalToConstant: width),
                ])
                rowsStack.addArrangedSubview(wrap)

            case .labelValue(let label, let value):
                rowsStack.addArrangedSubview(makeLabelValueRow(
                    label: label,
                    value: value,
                    valueWidth: valueWidth,
                    width: width
                ))

            case .prompt(let label, let value):
                let clamped = PromptDisplayLayout.clampPromptForDisplay(value, width: valueWidth)
                let block = NSStackView()
                block.orientation = .vertical
                block.spacing = 0
                block.translatesAutoresizingMaskIntoConstraints = false
                block.addArrangedSubview(spacer(height: JobQueueLayout.promptMarginPx))
                block.addArrangedSubview(makeLabelValueRow(
                    label: label,
                    value: clamped,
                    valueWidth: valueWidth,
                    width: width,
                    wrapping: true
                ))
                block.addArrangedSubview(spacer(height: JobQueueLayout.promptMarginPx))
                block.widthAnchor.constraint(equalToConstant: width).isActive = true
                rowsStack.addArrangedSubview(block)

            case .inline(let label, let primary, let inlineParts):
                let row = NSStackView()
                row.orientation = .horizontal
                row.alignment = .firstBaseline
                row.spacing = 0
                row.translatesAutoresizingMaskIntoConstraints = false
                let lbl = makeLabel(label, muted: true)
                lbl.widthAnchor.constraint(equalToConstant: JobQueueLayout.labelWidth).isActive = true
                row.addArrangedSubview(lbl)
                let valueRow = NSStackView()
                valueRow.orientation = .horizontal
                valueRow.alignment = .firstBaseline
                valueRow.spacing = JobQueueLayout.inlineGapPx
                if !primary.isEmpty {
                    valueRow.addArrangedSubview(makeLabel(primary, muted: false))
                }
                for part in inlineParts {
                    valueRow.addArrangedSubview(makeLabel(part.0, muted: true))
                    valueRow.addArrangedSubview(makeLabel(part.1, muted: false))
                }
                row.addArrangedSubview(valueRow)
                row.widthAnchor.constraint(equalToConstant: width).isActive = true
                rowsStack.addArrangedSubview(row)

            case .unavailable(let heading, let copiesLine, let promptLine):
                let block = NSStackView()
                block.orientation = .vertical
                block.spacing = 2
                block.translatesAutoresizingMaskIntoConstraints = false
                block.addArrangedSubview(makeLabel(heading, muted: false, bold: true))
                block.addArrangedSubview(makeLabel(copiesLine, muted: false))
                block.addArrangedSubview(makeLabel(promptLine, muted: false))
                block.widthAnchor.constraint(equalToConstant: width).isActive = true
                rowsStack.addArrangedSubview(block)

            case .banner(let text):
                let field = makeLabel(text, muted: false, wrapping: true)
                field.preferredMaxLayoutWidth = width
                let wrap = NSView()
                wrap.translatesAutoresizingMaskIntoConstraints = false
                field.translatesAutoresizingMaskIntoConstraints = false
                wrap.addSubview(field)
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
                    field.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
                    field.topAnchor.constraint(equalTo: wrap.topAnchor),
                    field.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
                    wrap.widthAnchor.constraint(equalToConstant: width),
                ])
                rowsStack.addArrangedSubview(wrap)
            }
        }

        invalidateIntrinsicContentSize()
    }

    private func makeLabelValueRow(
        label: String,
        value: String,
        valueWidth: CGFloat,
        width: CGFloat,
        wrapping: Bool = false
    ) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 2
        row.translatesAutoresizingMaskIntoConstraints = false
        let lbl = makeLabel(label, muted: true)
        lbl.widthAnchor.constraint(equalToConstant: JobQueueLayout.labelWidth).isActive = true
        row.addArrangedSubview(lbl)
        let val = makeLabel(value, muted: false, wrapping: wrapping)
        if wrapping {
            val.preferredMaxLayoutWidth = valueWidth
            val.widthAnchor.constraint(equalToConstant: valueWidth).isActive = true
        }
        row.addArrangedSubview(val)
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }

    private func makeLabel(
        _ text: String,
        muted: Bool,
        bold: Bool = false,
        wrapping: Bool = false
    ) -> NSTextField {
        let field = wrapping
            ? NSTextField(wrappingLabelWithString: text)
            : NSTextField(labelWithString: text)
        field.font = bold
            ? .boldSystemFont(ofSize: JobQueueLayout.fontSize)
            : .systemFont(ofSize: JobQueueLayout.fontSize)
        field.textColor = muted ? NSColor(colors.jobQueueMutedText) : NSColor(colors.sidebarText)
        field.isEditable = false
        field.isBezeled = false
        field.drawsBackground = false
        field.lineBreakMode = .byWordWrapping
        return field
    }

    private func spacer(height: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    override var intrinsicContentSize: NSSize {
        let height = max(rowsStack.fittingSize.height, 1)
        return NSSize(width: contentWidth > 0 ? contentWidth : NSView.noIntrinsicMetric, height: height)
    }
}
