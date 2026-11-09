import AppKit
import SwiftUI

/// Bottom chat message field (port of Python ``ChatPromptPlainTextEdit``).
@MainActor
final class ChatComposePromptNSTextView: NSTextView {
    var onCommandReturn: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if ChatKeyCommand.isCommandReturn(event) {
            onCommandReturn?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
    }
}

@MainActor
final class ChatComposePromptHostView: NSView {
    let scrollView: ChatComposePromptScrollView
    let textView: ChatComposePromptNSTextView

    private let minHeight: CGFloat = 44
    private let maxHeight: CGFloat = 140
    var onExitKeyboardFocus: (() -> Void)?
    private var clickAwayMonitor: Any?

    init() {
        scrollView = ChatComposePromptScrollView()
        textView = ChatComposePromptNSTextView()
        super.init(frame: .zero)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.allowsUndo = true
        ImageGenPromptPlainTextFieldSettings.applyUnicodePlainTextInputDefaults(to: textView)
        ImageGenPromptPlainTextFieldSettings.applyAutomaticTextReplacementEnabled(to: textView)

        scrollView.documentView = textView
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight),
            scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: maxHeight),
        ])
    }

    func applyChrome(textColor: NSColor, backgroundColor: NSColor) {
        textView.textColor = textColor
        textView.backgroundColor = .clear
        scrollView.drawsBackground = false
        if backgroundColor != .clear {
            scrollView.backgroundColor = backgroundColor
        }
    }

    func setInputEnabled(_ enabled: Bool) {
        guard textView.isEditable != enabled else { return }
        textView.isEditable = enabled
        textView.isSelectable = true
    }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== textView {
            window?.makeFirstResponder(textView)
        }
        textView.mouseDown(with: event)
    }

    func refreshDocumentLayout() {
        guard bounds.width > 1 else { return }
        let width = scrollView.contentView.bounds.width
        guard width > 1 else { return }
        guard let container = textView.textContainer,
              let layoutManager = textView.layoutManager else { return }
        container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        let contentHeight = used.height + textView.textContainerInset.height * 2
        let height = min(maxHeight, max(minHeight, contentHeight))
        textView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let showScroller = contentHeight > maxHeight + 0.5
        if scrollView.hasVerticalScroller != showScroller {
            scrollView.hasVerticalScroller = showScroller
        }
    }

    override func layout() {
        super.layout()
        refreshDocumentLayout()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            refreshDocumentLayout()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let onExitKeyboardFocus else { return }
        ChatTextFieldFocusRouting.syncClickAwayMonitor(
            host: self,
            textView: textView,
            onExit: onExitKeyboardFocus,
            storage: &clickAwayMonitor
        )
    }

    deinit {
        if let clickAwayMonitor {
            NSEvent.removeMonitor(clickAwayMonitor)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
final class ChatComposePromptScrollView: NSScrollView {
    override func mouseDown(with event: NSEvent) {
        if let textView = documentView as? NSTextView {
            window?.makeFirstResponder(textView)
        }
        super.mouseDown(with: event)
    }
}

struct ChatComposePromptTextView: NSViewRepresentable {
    @Binding var text: String
    var textColor: NSColor
    var backgroundColor: NSColor
    var inputEnabled: Bool
    var isStreaming: Bool
    var onCommandReturn: () -> Void
    var onExitKeyboardFocus: () -> Void
    var onTextChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> ChatComposePromptHostView {
        let host = ChatComposePromptHostView()
        host.textView.string = text
        host.textView.delegate = context.coordinator
        host.textView.onCommandReturn = { context.coordinator.fireCommandReturn() }
        host.applyChrome(textColor: textColor, backgroundColor: backgroundColor)
        host.setInputEnabled(inputEnabled)
        host.onExitKeyboardFocus = onExitKeyboardFocus
        context.coordinator.wasStreaming = isStreaming
        host.refreshDocumentLayout()
        return host
    }

    func updateNSView(_ host: ChatComposePromptHostView, context: Context) {
        context.coordinator.parent = self
        host.onExitKeyboardFocus = onExitKeyboardFocus
        host.textView.onCommandReturn = { context.coordinator.fireCommandReturn() }
        host.applyChrome(textColor: textColor, backgroundColor: backgroundColor)
        host.setInputEnabled(inputEnabled)
        let wasStreaming = context.coordinator.wasStreaming
        context.coordinator.wasStreaming = isStreaming
        if wasStreaming, !isStreaming, inputEnabled {
            DispatchQueue.main.async {
                host.window?.makeFirstResponder(host.textView)
            }
        }
        if context.coordinator.isUpdatingFromView { return }
        if host.textView.hasMarkedText() { return }
        if host.textView.string != text {
            let selected = host.textView.selectedRange()
            host.textView.string = text
            let length = (text as NSString).length
            if selected.location <= length {
                host.textView.setSelectedRange(selected)
            }
        }
        host.refreshDocumentLayout()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatComposePromptTextView
        var isUpdatingFromView = false
        var wasStreaming = false

        init(parent: ChatComposePromptTextView) {
            self.parent = parent
        }

        func fireCommandReturn() {
            parent.onCommandReturn()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if ChatKeyCommand.isCommandReturn(modifiers: flags) {
                parent.onCommandReturn()
                return true
            }
            return false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if textView.hasMarkedText() { return }
            let value = textView.string
            isUpdatingFromView = true
            if parent.text != value {
                parent.text = value
            }
            parent.onTextChange(value)
            isUpdatingFromView = false
        }
    }
}
