import AppKit
import SwiftUI

/// Editable multiline reference prompt (SwiftUI ``TextEditor`` is unreliable in Preferences sheets).
struct LoRAReferencePromptEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = LoRAReferencePromptScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true

        let textView = LoRAReferencePromptTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        ImageGenPromptPlainTextFieldSettings.applyUnicodePlainTextInputDefaults(to: textView)
        textView.textContainerInset = NSSize(width: 4, height: 5)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = text
        textView.delegate = context.coordinator

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        if context.coordinator.isUpdatingFromView { return }
        if textView.hasMarkedText() { return }
        if textView.string != text {
            ImageGenPromptPlainTextFieldSettings.replaceProgrammaticFullText(
                text,
                on: textView,
                preservingSelectionFrom: textView.selectedRange()
            )
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        weak var textView: NSTextView?
        var isUpdatingFromView = false
        private var commitObserver: NSObjectProtocol?

        init(text: Binding<String>) {
            _text = text
            super.init()
            commitObserver = NotificationCenter.default.addObserver(
                forName: .prowserCommitImageGenPromptSentenceCase,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.normalizeInMemoryOnBlur()
                }
            }
        }

        deinit {
            if let commitObserver {
                NotificationCenter.default.removeObserver(commitObserver)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            if textView.hasMarkedText() { return }
            isUpdatingFromView = true
            text = textView.string
            isUpdatingFromView = false
        }

        func textDidEndEditing(_ notification: Notification) {
            normalizeInMemoryOnBlur()
        }

        /// Sentence-case the bound string only (same as SwiftUI blur hooks); no catalog or settings I/O.
        private func normalizeInMemoryOnBlur() {
            guard let textView else { return }
            let normalized = ImageGenPromptSentenceCase.normalized(textView.string, perLine: true)
            guard normalized != textView.string else { return }
            isUpdatingFromView = true
            ImageGenPromptPlainTextFieldSettings.replaceProgrammaticFullText(
                normalized,
                on: textView,
                preservingSelectionFrom: textView.selectedRange()
            )
            text = normalized
            isUpdatingFromView = false
        }
    }
}

private final class LoRAReferencePromptTextView: NSTextView {
    override var acceptsFirstResponder: Bool { true }
}

private final class LoRAReferencePromptScrollView: NSScrollView {
    override func mouseDown(with event: NSEvent) {
        if let textView = documentView as? NSTextView {
            window?.makeFirstResponder(textView)
        }
        super.mouseDown(with: event)
    }
}
