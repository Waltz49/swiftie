import AppKit

/// Width-aware prompt clamping for job card display (2-line max, word-boundary elide).
/// Port of `imagegen_plugins/prompt_display_layout.py`.
enum PromptDisplayLayout {
    private static let ellipsis = "…"

    static func clampPromptForDisplay(
        _ text: String,
        width: CGFloat,
        font: NSFont = .systemFont(ofSize: JobQueueLayout.fontSize),
        maxLines: Int = JobQueueLayout.promptMaxLines
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, width > 0 else { return trimmed }
        if lineCount(trimmed, width: width, font: font) <= maxLines {
            return trimmed
        }
        let starts = lineStartIndices(trimmed, width: width, font: font)
        guard starts.count > maxLines else { return trimmed }
        var cut = starts[maxLines]
        cut = snapToWordBoundary(trimmed, cut: cut)
        while cut > 0 {
            let candidate = trimmed.prefix(cut).trimmingCharacters(in: .whitespaces) + ellipsis
            if lineCount(String(candidate), width: width, font: font) <= maxLines {
                return String(candidate)
            }
            let prevSpace = trimmed[..<trimmed.index(trimmed.startIndex, offsetBy: cut)].lastIndex(of: " ")
            if let prevSpace {
                cut = trimmed.distance(from: trimmed.startIndex, to: prevSpace)
            } else {
                cut -= 1
            }
        }
        return ellipsis
    }

    private static func lineCount(_ text: String, width: CGFloat, font: NSFont) -> Int {
        lineStartIndices(text, width: width, font: font).count
    }

    private static func lineStartIndices(_ text: String, width: CGFloat, font: NSFont) -> [Int] {
        guard !text.isEmpty, width > 0 else { return [] }
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        var starts: [Int] = []
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, glyphRange, _ in
            let charRange = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            starts.append(charRange.location)
        }
        return starts
    }

    private static func snapToWordBoundary(_ text: String, cut: Int) -> Int {
        if cut <= 0 { return 0 }
        if cut >= text.count { return text.count }
        let prefix = text.prefix(cut)
        if let lastSpace = prefix.lastIndex(of: " ") {
            return text.distance(from: text.startIndex, to: lastSpace)
        }
        return cut
    }
}
