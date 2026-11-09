import AppKit

/// Tab exit and click-away for chat compose / inline edit (Python ``_ChatTabKeyFilter``).
@MainActor
enum ChatTextFieldFocusRouting {
    static func hitIsInsideChatTextField(_ view: NSView?) -> Bool {
        guard let view else { return false }
        var current: NSView? = view
        while let candidate = current {
            if candidate is ChatComposePromptHostView || candidate is ChatMessageEditHostView {
                return true
            }
            current = candidate.superview
        }
        return false
    }

    static func removeClickAwayMonitor(_ storage: inout Any?) {
        if let monitor = storage {
            NSEvent.removeMonitor(monitor)
            storage = nil
        }
    }

    static func syncClickAwayMonitor(
        host: NSView,
        textView: NSTextView,
        onExit: @escaping () -> Void,
        storage: inout Any?
    ) {
        removeClickAwayMonitor(&storage)
        guard host.window != nil else { return }
        storage = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window = host.window, event.window === window else { return event }
            MainActor.assumeIsolated {
                guard window.firstResponder === textView else { return }
                guard let contentView = window.contentView else {
                    onExit()
                    return
                }
                let point = contentView.convert(event.locationInWindow, from: nil)
                let hit = contentView.hitTest(point)
                guard !hitIsInsideChatTextField(hit) else { return }
                DispatchQueue.main.async {
                    guard window.firstResponder === textView else { return }
                    let current = contentView.hitTest(point)
                    if !hitIsInsideChatTextField(current) {
                        onExit()
                    }
                }
            }
            return event
        }
    }
}
