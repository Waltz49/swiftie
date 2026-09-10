import AppKit
import SwiftUI

/// Single clickable status bar section (Python `Clickable*Label` parity).
struct StatusBarSectionHost: NSViewRepresentable {
    var text: String
    var textColor: NSColor
    var enabled: Bool
    var isBold = false
    var alignment: NSTextAlignment = .left
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
        nsView.enabled = enabled
        nsView.onClick = enabled ? onClick : nil
        nsView.updateCursor()
    }
}

final class StatusBarSectionNSView: NSView {
    let label = NSTextField(labelWithString: "")
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
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
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
