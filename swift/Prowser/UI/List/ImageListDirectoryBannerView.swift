import AppKit

/// Full-width directory line above list column headers (does not scroll with columns).
@MainActor
final class ImageListDirectoryBannerView: NSView {
    static let fontSize: CGFloat = 14
    static let preferredHeight: CGFloat = 24

    var content: ImageListRowFormatting.DirectoryBannerContent? {
        didSet {
            guard oldValue != content else { return }
            needsDisplay = true
        }
    }

    var textColor: NSColor = ThemeColors.dark.thumbnailText.nsColor {
        didSet {
            guard oldValue != textColor else { return }
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let content else { return }
        let font = NSFont.systemFont(ofSize: Self.fontSize)
        let color = textColor
        let margin: CGFloat = 8
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let drawRect = NSRect(
            x: margin,
            y: 0,
            width: max(0, bounds.width - margin * 2),
            height: bounds.height
        )

        let displayText: String
        switch content.kind {
        case .plain(let text):
            displayText = text
        case .singleDirectory(let directory):
            displayText = prefixedPathText(
                prefix: ImageListRowFormatting.singleDirectoryBannerPrefix,
                path: directory,
                in: drawRect,
                attributes: attributes
            )
        case .multipleDirectories(let commonRoot):
            displayText = prefixedPathText(
                prefix: ImageListRowFormatting.multipleDirectoriesBannerPrefix,
                path: commonRoot,
                in: drawRect,
                attributes: attributes
            )
        }

        guard !displayText.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byTruncatingTail
        var drawAttributes = attributes
        drawAttributes[.paragraphStyle] = paragraph
        (displayText as NSString).draw(
            with: drawRect,
            options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin],
            attributes: drawAttributes
        )
    }

    private func prefixedPathText(
        prefix: String,
        path: String,
        in drawRect: NSRect,
        attributes: [NSAttributedString.Key: Any]
    ) -> String {
        let prefixWidth = (prefix as NSString).size(withAttributes: attributes).width
        let pathBudget = max(0, drawRect.width - prefixWidth)
        let pathText = elideLeading(path, maxWidth: pathBudget, attributes: attributes)
        return prefix + pathText
    }

    /// Keeps the end of `text` visible, replacing the start with `...` when needed.
    private func elideLeading(
        _ text: String,
        maxWidth: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) -> String {
        guard maxWidth > 0 else { return "…" }
        let fullWidth = (text as NSString).size(withAttributes: attributes).width
        if fullWidth <= maxWidth { return text }
        let ellipsis = "..."
        let ellipsisWidth = (ellipsis as NSString).size(withAttributes: attributes).width
        guard maxWidth > ellipsisWidth else { return ellipsis }

        for length in stride(from: text.count, through: 1, by: -1) {
            let suffix = String(text.suffix(length))
            let candidate = ellipsis + suffix
            let width = (candidate as NSString).size(withAttributes: attributes).width
            if width <= maxWidth {
                return candidate
            }
        }
        return ellipsis
    }
}
