import AppKit
import SwiftUI

@MainActor
final class ChatMessageEditNSTextView: NSTextView {
    var onCommandReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if ChatKeyCommand.isCommandReturn(event) {
            onCommandReturn?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if onEscape != nil {
            onEscape?()
        } else {
            super.cancelOperation(sender)
        }
    }

    override func keyDown(with event: NSEvent) {
        if ChatKeyCommand.isPlainEscape(event) {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
final class ChatMessageEditHostView: NSView {
    let scrollView: NSScrollView
    let textView: ChatMessageEditNSTextView
    var onExitKeyboardFocus: (() -> Void)?
    private var clickAwayMonitor: Any?

    init() {
        scrollView = NSScrollView()
        textView = ChatMessageEditNSTextView()
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
        textView.drawsBackground = true
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 72),
            scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: 180),
        ])
    }

    func applyChrome(textColor: NSColor, backgroundColor: NSColor) {
        textView.textColor = textColor
        textView.backgroundColor = backgroundColor
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
        let height = min(180, max(72, contentHeight))
        textView.frame = NSRect(x: 0, y: 0, width: width, height: height)
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

struct ChatMessageEditTextView: NSViewRepresentable {
    @Binding var text: String
    /// Message text when edit opens (used when SwiftUI binding lags behind ``editingMessageID``).
    var seedText: String
    var textColor: NSColor
    var backgroundColor: NSColor
    var onCommandReturn: () -> Void
    var onEscape: () -> Void
    var onExitKeyboardFocus: () -> Void
    var onTextChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> ChatMessageEditHostView {
        context.coordinator.prepareForNewEditSession()
        let host = ChatMessageEditHostView()
        let initial = text.isEmpty ? seedText : text
        host.textView.string = initial
        host.textView.delegate = context.coordinator
        host.textView.onCommandReturn = { context.coordinator.fireCommandReturn() }
        host.textView.onEscape = { context.coordinator.fireEscape() }
        host.applyChrome(textColor: textColor, backgroundColor: backgroundColor)
        host.onExitKeyboardFocus = onExitKeyboardFocus
        context.coordinator.seedBindingIfNeeded(displayed: initial)
        host.refreshDocumentLayout()
        DispatchQueue.main.async {
            host.window?.makeFirstResponder(host.textView)
        }
        return host
    }

    func updateNSView(_ host: ChatMessageEditHostView, context: Context) {
        context.coordinator.parent = self
        host.onExitKeyboardFocus = onExitKeyboardFocus
        host.textView.onCommandReturn = { context.coordinator.fireCommandReturn() }
        host.textView.onEscape = { context.coordinator.fireEscape() }
        host.applyChrome(textColor: textColor, backgroundColor: backgroundColor)
        let hostLen = host.textView.string.count
        let willOverwriteWithEmpty = text.isEmpty && hostLen > 0
        if willOverwriteWithEmpty {
            context.coordinator.seedBindingIfNeeded(displayed: host.textView.string)
            host.refreshDocumentLayout()
            return
        }
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
        var parent: ChatMessageEditTextView
        private var didSeedBinding = false

        init(parent: ChatMessageEditTextView) {
            self.parent = parent
        }

        func prepareForNewEditSession() {
            didSeedBinding = false
        }

        func seedBindingIfNeeded(displayed: String) {
            guard !didSeedBinding else { return }
            guard parent.text.isEmpty, !displayed.isEmpty else { return }
            didSeedBinding = true
            parent.text = displayed
            parent.onTextChange(displayed)
        }

        func fireCommandReturn() {
            parent.onCommandReturn()
        }

        func fireEscape() {
            parent.onEscape()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if ChatKeyCommand.isCommandReturn(modifiers: NSEvent.modifierFlags) {
                    fireCommandReturn()
                    return true
                }
                return false
            }
            return false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let value = textView.string
            if parent.text != value {
                parent.text = value
            }
            parent.onTextChange(value)
        }
    }
}
