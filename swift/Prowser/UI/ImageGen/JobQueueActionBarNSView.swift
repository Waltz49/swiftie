import AppKit

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

    func applyTheme(_ colors: ThemeColors) {
        layer?.backgroundColor = NSColor(colors.jobQueueActionBarBackground).cgColor
        for case let button as NSButton in stack.arrangedSubviews {
            styleButton(button, colors: colors)
        }
    }

    private func rebuildButtons() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.addArrangedSubview(iconButton(title: "Img", action: #selector(imgAction)))
        stack.addArrangedSubview(iconButton(title: "Txt", action: #selector(txtAction)))
        stack.addArrangedSubview(iconButton(title: "+", action: #selector(addAction)))
        stack.addArrangedSubview(iconButton(title: "−", action: #selector(subAction)))
        stack.addArrangedSubview(NSView())
        stack.addArrangedSubview(iconButton(title: "Edit", action: #selector(editAction)))
        stack.addArrangedSubview(iconButton(title: "✕", action: #selector(cancelAction)))
    }

    private func iconButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .shadowlessSquare
        button.font = .systemFont(ofSize: 10, weight: .medium)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: JobQueueLayout.actionButtonSize).isActive = true
        button.heightAnchor.constraint(equalToConstant: JobQueueLayout.actionButtonSize).isActive = true
        return button
    }

    private func styleButton(_ button: NSButton, colors: ThemeColors) {
        button.contentTintColor = NSColor(colors.sidebarText)
        button.wantsLayer = true
        button.layer?.cornerRadius = 3
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor(colors.defaultBorder).cgColor
        button.layer?.backgroundColor = NSColor(colors.jobQueueActionBarBackground).cgColor
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
    @objc private func imgAction() { onToggleImageRefinement?(true) }
    @objc private func txtAction() { onToggleTextRefinement?(true) }
}
