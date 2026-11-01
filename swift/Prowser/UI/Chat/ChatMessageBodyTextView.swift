import AppKit
import SwiftUI

/// Message body label: selectable text; double-click opens inline edit (Python ``_ChatMessageBodyLabel``).
@MainActor
final class ChatMessageBodyNSTextView: NSTextView {
    var onEditRequested: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.buttonNumber == 0, event.clickCount >= 2 {
            onEditRequested?()
            return
        }
        super.mouseDown(with: event)
    }
}

@MainActor
final class ChatMessageBodyHostView: NSView {
    let textView: ChatMessageBodyNSTextView

    override var intrinsicContentSize: NSSize {
        let width = bounds.width > 1 ? bounds.width : 320
        let height = Self.fittingHeight(for: textView, width: width)
        return NSSize(width: NSView.noIntrinsicMetric, height: max(height, 1))
    }

    static func fittingHeight(for textView: NSTextView, width: CGFloat) -> CGFloat {
        guard let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager
        else { return 20 }
        textContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return used.height + textView.textContainerInset.height * 2
    }

    init() {
        textView = ChatMessageBodyNSTextView()
        super.init(frame: .zero)
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.textContainerInset = .zero
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = .zero
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(text: String, color: NSColor) {
        if textView.string != text {
            textView.string = text
        }
        textView.textColor = color
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()
        invalidateIntrinsicContentSize()
    }
}

struct ChatMessageBodyTextView: NSViewRepresentable {
    let text: String
    let textColor: NSColor
    var onDoubleClick: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDoubleClick: onDoubleClick)
    }

    func makeNSView(context: Context) -> ChatMessageBodyHostView {
        let host = ChatMessageBodyHostView()
        host.textView.onEditRequested = { context.coordinator.fireEditRequest() }
        host.apply(text: text, color: textColor)
        return host
    }

    func updateNSView(_ host: ChatMessageBodyHostView, context: Context) {
        context.coordinator.onDoubleClick = onDoubleClick
        host.textView.onEditRequested = { context.coordinator.fireEditRequest() }
        host.apply(text: text, color: textColor)
    }

    @MainActor
    final class Coordinator {
        var onDoubleClick: () -> Void

        init(onDoubleClick: @escaping () -> Void) {
            self.onDoubleClick = onDoubleClick
        }

        func fireEditRequest() {
            onDoubleClick()
        }
    }
}
