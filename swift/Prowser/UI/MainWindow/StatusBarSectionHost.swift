import AppKit
import SwiftUI

/// Single clickable status bar section (Python `Clickable*Label` parity).
struct StatusBarSectionHost: NSViewRepresentable {
    var text: String
    var textColor: NSColor
    var enabled: Bool
    var isBold = false
    var alignment: NSTextAlignment = .left
    var trailingIcon: NSImage?
    var onClick: ((NSView) -> Void)?

    func makeNSView(context: Context) -> StatusBarSectionNSView {
        let view = StatusBarSectionNSView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: StatusBarSectionNSView, context: Context) {
        nsView.label.stringValue = text
        nsView.label.textColor = textColor
        nsView.label.font = isBold
            ? NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            : .systemFont(ofSize: NSFont.smallSystemFontSize)
        nsView.label.alignment = alignment
        nsView.trailingIcon = trailingIcon
        nsView.enabled = enabled
        nsView.onClick = enabled ? onClick : nil
        nsView.updateCursor()
        nsView.needsLayout = true
    }
}

final class StatusBarSectionNSView: NSView {
    let label = NSTextField(labelWithString: "")
    let iconView = NSImageView()
    private var iconWidthConstraint: NSLayoutConstraint!
    private var iconLeadingConstraint: NSLayoutConstraint!

    var trailingIcon: NSImage? {
        didSet {
            iconView.image = trailingIcon
            let hasIcon = trailingIcon != nil
            iconView.isHidden = !hasIcon
            iconWidthConstraint.constant = hasIcon ? 12 : 0
            iconLeadingConstraint.constant = hasIcon ? 4 : 0
            needsLayout = true
        }
    }
    var onClick: ((NSView) -> Void)?
    var enabled = true {
        didSet { updateCursor() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isSelectable = false
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.isHidden = true

        addSubview(label)
        addSubview(iconView)
        let trailing = label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -5)
        trailing.priority = .defaultLow
        iconWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: 0)
        iconLeadingConstraint = iconView.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 0)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing,
            iconLeadingConstraint,
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidthConstraint,
            iconView.heightAnchor.constraint(equalToConstant: 12),
            iconView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func updateCursor() {
        if enabled, onClick != nil {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        updateCursor()
    }

    override func mouseDown(with event: NSEvent) {
        guard enabled, let onClick else { return }
        onClick(self)
    }
}
