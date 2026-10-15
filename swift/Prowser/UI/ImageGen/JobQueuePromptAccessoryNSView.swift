import AppKit

/// Full prompt block for dialogs (job-card label/value layout, scrollable value).
/// Port of job queue ``JobCardStatusNSView`` prompt row without width clamping.
@MainActor
final class JobQueuePromptAccessoryNSView: NSView {
    static let preferredScrollHeight: CGFloat = 80

    private let scrollView: NSScrollView
    private let textView: NSTextView

    init(prompt: String) {
        scrollView = NSScrollView()
        textView = NSTextView()

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "Prompt:")
        label.font = .systemFont(ofSize: JobQueueLayout.fontSize)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.font = .systemFont(ofSize: JobQueueLayout.fontSize)
        textView.textColor = .labelColor
        textView.string = prompt
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: JobQueueLayout.promptMarginPx),
            label.widthAnchor.constraint(equalToConstant: JobQueueLayout.labelWidth),

            scrollView.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 2),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: Self.preferredScrollHeight),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let width = max(scrollView.bounds.width, scrollView.contentSize.width)
        guard width > 1 else { return }
        textView.textContainer?.containerSize = NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
    }
}
