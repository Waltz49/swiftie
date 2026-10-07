import AppKit

struct JobQueueActionBarState {
    var hasRow = false
    var canAddSeries = false
    var canSubtractSeries = false
    var imageRefinementVisible = false
    var textRefinementVisible = false
    var imageRefinementChecked = false
    var textRefinementChecked = false

    static let empty = JobQueueActionBarState()
}

/// Per-card action bar embedded when selected. Port of `JobQueueActionBar` in Python.
@MainActor
final class JobQueueActionBarNSView: NSView {
    var onEdit: (() -> Void)?
    var onCancel: ((Bool) -> Void)?
    var onAddSeries: ((Int, Bool) -> Void)?
    var onSubtractSeries: ((Int, Bool) -> Void)?
    var onToggleImageRefinement: ((Bool) -> Void)?
    var onToggleTextRefinement: ((Bool) -> Void)?

    private let stack = NSStackView()
    private var imageRefineButton: NSAssetIconButton?
    private var textRefineButton: NSAssetIconButton?
    private var plusButton: NSAssetIconButton?
    private var minusButton: NSAssetIconButton?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: JobQueueLayout.actionBarHeight),
        ])
        rebuildButtons()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(state: JobQueueActionBarState) {
        imageRefineButton?.isHidden = !state.imageRefinementVisible
        textRefineButton?.isHidden = !state.textRefinementVisible
        imageRefineButton?.showsActiveIcon = state.imageRefinementChecked
        textRefineButton?.showsActiveIcon = state.textRefinementChecked
        plusButton?.isEnabled = state.canAddSeries
        minusButton?.isEnabled = state.canSubtractSeries
        for case let button as NSButton in stack.arrangedSubviews where button !== plusButton && button !== minusButton {
            if button === imageRefineButton || button === textRefineButton {
                continue
            }
            button.isEnabled = state.hasRow
        }
    }

    func applyTheme(_ colors: ThemeColors) {
        layer?.backgroundColor = NSColor(colors.jobQueueActionBarBackground).cgColor
    }

    private func rebuildButtons() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        stack.addArrangedSubview(NSView())

        let imageButton = seriesToggleButton(
            baseName: "series_image_refinement_icon",
            tooltip: """
            Image Based Refinement:

            Base subsequent image copies on previous result image.

            Other source images, if any, keep their order.
            """,
            action: #selector(imgAction)
        )
        imageRefineButton = imageButton
        stack.addArrangedSubview(imageButton)

        let textButton = seriesToggleButton(
            baseName: "series_text_refinement_icon",
            tooltip: """
            Text Based Refinement:

            Re-run the previous prompt through Gen Prompt AI before each
            subsequent copy in the series.
            """,
            action: #selector(txtAction)
        )
        textRefineButton = textButton
        stack.addArrangedSubview(textButton)

        stack.addArrangedSubview(assetIconButton(
            normalName: "edit_icon",
            hoverName: "edit_icon_hover",
            tooltip: """
            Replicate job settings…
            For a pending job, use Replace in the dialog to update it in place.
            For a running batch job, use Update to change remaining copies.
            """,
            action: #selector(editAction)
        ))

        let plus = assetIconButton(
            normalName: "series_plus_icon",
            hoverName: "series_plus_icon_hover",
            tooltip: """
            Add another image to this series
            Option+click to set copies to 51 (runs continuously).
            """,
            action: #selector(addAction)
        )
        plusButton = plus
        stack.addArrangedSubview(plus)

        let minus = assetIconButton(
            normalName: "series_minus_icon",
            hoverName: "series_minus_icon_hover",
            tooltip: """
            Remove one pending image from the series.
            Option+click to remove all remaining images.
            """,
            action: #selector(subAction)
        )
        minusButton = minus
        stack.addArrangedSubview(minus)

        stack.addArrangedSubview(assetIconButton(
            normalName: "trash_icon",
            hoverName: "trash_icon_hover",
            tooltip: "Cancel job\nOption+click to cancel this job and all jobs after it (no confirmation).",
            action: #selector(cancelAction)
        ))
    }

    private func seriesToggleButton(baseName: String, tooltip: String, action: Selector) -> NSAssetIconButton {
        let button = NSAssetIconButton(
            normalName: baseName,
            hoverName: "\(baseName)_hover",
            activeNormalName: "\(baseName)_active",
            activeHoverName: "\(baseName)_active_hover",
            size: JobQueueLayout.actionButtonSize,
            tooltip: tooltip
        )
        button.target = self
        button.action = action
        return button
    }

    private func assetIconButton(
        normalName: String,
        hoverName: String,
        tooltip: String,
        action: Selector
    ) -> NSAssetIconButton {
        let button = NSAssetIconButton(
            normalName: normalName,
            hoverName: hoverName,
            size: JobQueueLayout.actionButtonSize,
            tooltip: tooltip
        )
        button.target = self
        button.action = action
        return button
    }

    @objc private func editAction() { onEdit?() }
    @objc private func cancelAction() {
        onCancel?(NSEvent.modifierFlags.contains(.option))
    }
    @objc private func addAction() {
        onAddSeries?(1, NSEvent.modifierFlags.contains(.option))
    }
    @objc private func subAction() {
        onSubtractSeries?(1, NSEvent.modifierFlags.contains(.option))
    }
    @objc private func imgAction() {
        let enabled = !(imageRefineButton?.showsActiveIcon ?? false)
        onToggleImageRefinement?(enabled)
    }
    @objc private func txtAction() {
        let enabled = !(textRefineButton?.showsActiveIcon ?? false)
        onToggleTextRefinement?(enabled)
    }
}
