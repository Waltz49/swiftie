import AppKit
import SwiftUI

// MARK: - Layout (Python ``image_gen_form_layout`` parity)

enum ImageGenPromptLayout {
    static let defaultMinLines = 4
    static let defaultMaxLines = 22

    static let negativeMinLines = 2
    static let negativeMaxLines = 5

    static let createSheetMinLines = 3
    static let createSheetMaxLines = 8

    static let systemPromptMinLines = 6
    static let systemPromptMaxLines = 12

    /// Python ``IMAGE_GEN_PROMPT_STYLE_PADDING_V`` + ``IMAGE_GEN_PROMPT_STYLE_BORDER_V``.
    private static let stylePaddingV: CGFloat = 10
    private static let styleBorderV: CGFloat = 2
    private static let heightFudge: CGFloat = 2

    static func heightForLines(_ lineCount: Int, font: NSFont) -> CGFloat {
        let lines = max(1, lineCount)
        let lineHeight = font.ascender - font.descender + font.leading
        return lineHeight * CGFloat(lines) + lineHeight * 0.5 + stylePaddingV + styleBorderV + heightFudge
    }

    static func clampedVisibleLines(contentLines: Int, minLines: Int, maxLines: Int) -> Int {
        max(minLines, min(max(1, contentLines), maxLines))
    }
}

/// Tracks flux AI streaming into the main image prompt field (Python stream scroll session).
@MainActor
final class ImageGenPromptStreamSession {
    private(set) var isActive = false

    func begin() { isActive = true }
    func end() { isActive = false }
}

// MARK: - Text view

/// Prompt field with standard ⌘Z / ⌘⇧Z undo when the global keyboard monitor passes key events through.
@MainActor
final class ImageGenPromptNSTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option),
              event.charactersIgnoringModifiers?.lowercased() == "z"
        else {
            return super.performKeyEquivalent(with: event)
        }
        if flags.contains(.shift) {
            if undoManager?.canRedo == true {
                undoManager?.redo()
                return true
            }
        } else if undoManager?.canUndo == true {
            undoManager?.undo()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if let scrollView = enclosingScrollView {
            scrollView.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

// MARK: - SwiftUI

struct ImageGenPromptPlainTextEdit: NSViewRepresentable {
    @Binding var text: String
    var minLines: Int = ImageGenPromptLayout.defaultMinLines
    var maxLines: Int = ImageGenPromptLayout.defaultMaxLines
    var sentenceCasePerLine = false
    var streamSession: ImageGenPromptStreamSession?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            minLines: minLines,
            maxLines: maxLines,
            sentenceCasePerLine: sentenceCasePerLine,
            streamSession: streamSession
        )
    }

    func makeNSView(context: Context) -> ImageGenPromptPlainTextHostView {
        let host = ImageGenPromptPlainTextHostView()
        context.coordinator.attach(host: host)
        host.configure(
            text: text,
            minLines: minLines,
            maxLines: maxLines,
            coordinator: context.coordinator
        )
        return host
    }

    func updateNSView(_ host: ImageGenPromptPlainTextHostView, context: Context) {
        context.coordinator.minLines = minLines
        context.coordinator.maxLines = maxLines
        context.coordinator.sentenceCasePerLine = sentenceCasePerLine
        context.coordinator.streamSession = streamSession
        context.coordinator.applyExternalText(text, host: host)
        host.setLineLimits(minLines: minLines, maxLines: maxLines)
        host.refreshHeightAndScrollPolicy()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var minLines: Int
        var maxLines: Int
        var sentenceCasePerLine: Bool
        weak var streamSession: ImageGenPromptStreamSession?

        private weak var textView: NSTextView?
        private weak var host: ImageGenPromptPlainTextHostView?
        private var isEditing = false
        private var streamLastText = ""
        private var wasStreamActive = false

        init(
            text: Binding<String>,
            minLines: Int,
            maxLines: Int,
            sentenceCasePerLine: Bool,
            streamSession: ImageGenPromptStreamSession?
        ) {
            _text = text
            self.minLines = minLines
            self.maxLines = maxLines
            self.sentenceCasePerLine = sentenceCasePerLine
            self.streamSession = streamSession
        }

        func attach(host: ImageGenPromptPlainTextHostView) {
            self.host = host
            self.textView = host.textView
            host.textView.delegate = self
            host.textView.undoManager?.levelsOfUndo = 100
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            if textView.hasMarkedText() { return }
            isEditing = true
            let newValue = textView.string
            if text != newValue {
                text = newValue
            }
            isEditing = false
            host?.refreshHeightAndScrollPolicy()
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let textView else { return }
            let normalized = ImageGenPromptSentenceCase.normalized(
                textView.string,
                perLine: sentenceCasePerLine
            )
            if normalized != textView.string {
                textView.string = normalized
                text = normalized
            }
            host?.refreshHeightAndScrollPolicy()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                return false
            }
            return false
        }

        func applyExternalText(_ newText: String, host: ImageGenPromptPlainTextHostView) {
            guard let textView else { return }
            if isEditing || textView.hasMarkedText() { return }

            let streamActive = streamSession?.isActive == true
            if streamActive, !wasStreamActive {
                wasStreamActive = true
                host.resetStreamScrollState()
                streamLastText = textView.string
            } else if !streamActive, wasStreamActive {
                wasStreamActive = false
                streamLastText = ""
            }

            let current = textView.string
            if current == newText { return }

            if streamActive {
                applyStreamingText(newText, textView: textView, host: host)
                if text != newText { text = newText }
                return
            }

            streamLastText = ""
            preserveSelectionSetString(newText, on: textView)
            host.refreshHeightAndScrollPolicy()
        }

        private func applyStreamingText(
            _ newText: String,
            textView: NSTextView,
            host: ImageGenPromptPlainTextHostView
        ) {
            let old = streamLastText.isEmpty ? textView.string : streamLastText
            if let delta = ImageGenPromptTextEncoding.suffix(afterPrefix: old, in: newText), !delta.isEmpty {
                appendStreaming(delta, textView: textView, host: host)
            } else if newText != textView.string {
                preserveSelectionSetString(newText, on: textView)
                host.refreshHeightAndScrollPolicy()
                scrollToEndIfFollowing(textView: textView, host: host)
            }
            streamLastText = newText
        }

        private func appendStreaming(
            _ delta: String,
            textView: NSTextView,
            host: ImageGenPromptPlainTextHostView
        ) {
            let scrollView = host.scrollView
            let userScrolled = host.userScrolledDuringStream
            let preservedY = scrollView.contentView.bounds.origin.y

            let range = ImageGenPromptTextEncoding.utf16EndInsertionRange(in: textView.string)
            textView.insertText(delta, replacementRange: range)
            host.refreshHeightAndScrollPolicy()

            if userScrolled {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: preservedY))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            } else {
                scrollToEndIfFollowing(textView: textView, host: host)
            }
        }

        private func scrollToEndIfFollowing(textView: NSTextView, host: ImageGenPromptPlainTextHostView) {
            guard !host.userScrolledDuringStream else { return }
            let length = ImageGenPromptTextEncoding.utf16Length(of: textView.string)
            textView.scrollRangeToVisible(NSRange(location: max(0, length - 1), length: 1))
        }

        private func preserveSelectionSetString(_ newText: String, on textView: NSTextView) {
            let selected = textView.selectedRange()
            textView.string = newText
            let len = ImageGenPromptTextEncoding.utf16Length(of: newText)
            if selected.location <= len {
                textView.setSelectedRange(selected)
            } else {
                textView.setSelectedRange(NSRange(location: len, length: 0))
            }
        }
    }
}

// MARK: - Host view

@MainActor
final class ImageGenPromptPlainTextHostView: NSView {
    let scrollView = ImageGenNonForwardingScrollView()
    let textView = ImageGenPromptNSTextView()

    private var heightConstraint: NSLayoutConstraint?
    private var minLines = ImageGenPromptLayout.defaultMinLines
    private var maxLines = ImageGenPromptLayout.defaultMaxLines
    private weak var coordinator: ImageGenPromptPlainTextEdit.Coordinator?

    private(set) var userScrolledDuringStream = false
    private var streamScrollObservation: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        textView.isRichText = false
        textView.importsGraphics = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 4, height: 5)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)

        let height = heightAnchor.constraint(equalToConstant: 80)
        heightConstraint = height

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            height,
        ])

        scrollView.contentView.postsBoundsChangedNotifications = true
        streamScrollObservation = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.noteScrollByUser()
            }
        }
    }

    deinit {
        if let streamScrollObservation {
            NotificationCenter.default.removeObserver(streamScrollObservation)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: heightConstraint?.constant ?? 80)
    }

    override func layout() {
        super.layout()
        refreshHeightAndScrollPolicy()
    }

    override func scrollWheel(with event: NSEvent) {
        scrollView.scrollWheel(with: event)
    }

    func configure(
        text: String,
        minLines: Int,
        maxLines: Int,
        coordinator: ImageGenPromptPlainTextEdit.Coordinator
    ) {
        self.coordinator = coordinator
        self.minLines = minLines
        self.maxLines = maxLines
        textView.string = text
        refreshHeightAndScrollPolicy()
    }

    func setLineLimits(minLines: Int, maxLines: Int) {
        self.minLines = minLines
        self.maxLines = maxLines
    }

    func refreshHeightAndScrollPolicy() {
        let font = textView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let contentLines = Self.contentLineCount(textView: textView)
        let visibleLines = ImageGenPromptLayout.clampedVisibleLines(
            contentLines: contentLines,
            minLines: minLines,
            maxLines: maxLines
        )
        let atMax = contentLines >= maxLines
        if scrollView.hasVerticalScroller != atMax {
            scrollView.hasVerticalScroller = atMax
        }
        let targetHeight = ImageGenPromptLayout.heightForLines(visibleLines, font: font)
        if heightConstraint?.constant != targetHeight {
            heightConstraint?.constant = targetHeight
            invalidateIntrinsicContentSize()
        }
    }

    private func noteScrollByUser() {
        guard coordinator?.streamSession?.isActive == true else { return }
        userScrolledDuringStream = true
    }

    func resetStreamScrollState() {
        userScrolledDuringStream = false
    }

    static func contentLineCount(textView: NSTextView) -> Int {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else { return 1 }

        let inset = textView.textContainerInset.width * 2
        let width = max(1, textView.bounds.width - inset)
        if width > 1 {
            textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        layoutManager.ensureLayout(for: textContainer)

        if ImageGenPromptTextEncoding.utf16Length(of: textView.string) == 0 {
            return 1
        }

        var lineCount = 0
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, _, _ in
            lineCount += 1
        }
        return max(1, lineCount)
    }
}
