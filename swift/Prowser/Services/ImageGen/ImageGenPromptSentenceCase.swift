import Foundation
import SwiftUI

/// Blur-time prompt normalization (port of ``image_gen_form_layout`` sentence-case helpers).
enum ImageGenPromptSentenceCase {
    private static let trailingPunctNoPeriod: Set<Character> = [".", ":", "?", "!"]
    private static let sentenceStartRegex = try! NSRegularExpression(
        pattern: #"(^|[.!?;:*]\s*|\n\n+|\s-\s*)(\w)"#
    )
    private static let horizontalBlankRegex = try! NSRegularExpression(pattern: #"[ \t]+"#)
    private static let spaceBeforePeriodRegex = try! NSRegularExpression(pattern: #"\s+\. "#)

    /// Full blur/submit normalization (prepare + capitalize).
    static func normalized(_ text: String, perLine: Bool = false) -> String {
        let prepared = perLine ? prepareForSentenceCaseLines(text) : prepareForSentenceCase(text)
        return perLine ? sentenceCaseLines(prepared) : sentenceCase(prepared)
    }

    /// Re-capitalize after AI exit output without lowercasing (``apply_sentence_case_after_prompt_exit``).
    static func afterPromptExit(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return text }
        let normalized = sentenceCase(text)
        return normalized == text ? text : normalized
    }

    static func flushPromptValues(_ values: inout [String: Any]) {
        for key in ["prompt", "negative_prompt"] {
            guard let raw = values[key] as? String else { continue }
            let normalized = normalized(raw, perLine: false)
            if normalized != raw {
                values[key] = normalized
            }
        }
    }

    static func sentenceCase(_ text: String) -> String {
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { return "" }
        let ns = stripped as NSString
        let range = NSRange(location: 0, length: ns.length)
        let mutable = NSMutableString(string: stripped)
        sentenceStartRegex.enumerateMatches(in: stripped, options: [], range: range) { match, _, _ in
            guard let match, match.numberOfRanges >= 3 else { return }
            let letterRange = match.range(at: 2)
            if letterRange.location == NSNotFound { return }
            let letter = ns.substring(with: letterRange)
            mutable.replaceCharacters(in: letterRange, with: letter.uppercased())
        }
        return mutable as String
    }

    static func sentenceCaseLines(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let s = String(line)
            return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? s : sentenceCase(s)
        }.joined(separator: "\n")
    }

    private static func prepareForSentenceCase(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let s = String(line)
            return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : normalizeLineContent(s)
        }
        lines = collapseConsecutiveBlankLines(lines)
        return ensureTrailingPeriod(lines.joined(separator: "\n"))
    }

    private static func prepareForSentenceCaseLines(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let s = String(line)
            return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : normalizeLineForSentenceCase(s)
        }
        lines = collapseConsecutiveBlankLines(lines)
        return lines.joined(separator: "\n")
    }

    private static func normalizeLineForSentenceCase(_ line: String) -> String {
        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        return ensureTrailingPeriod(normalizeLineContent(line))
    }

    private static func normalizeLineContent(_ line: String) -> String {
        normalizePeriodSpacing(collapseDuplicateBlanks(line).lowercased())
    }

    private static func collapseDuplicateBlanks(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return replaceMatches(in: trimmed, regex: horizontalBlankRegex, with: " ")
    }

    private static func normalizePeriodSpacing(_ text: String) -> String {
        replaceMatches(in: text, regex: spaceBeforePeriodRegex, with: ". ")
    }

    private static func ensureTrailingPeriod(_ text: String) -> String {
        let stripped = text.trimmingCharacters(in: .whitespaces)
        if stripped.isEmpty { return text }
        if let last = stripped.last, trailingPunctNoPeriod.contains(last) {
            return text
        }
        return stripped + "."
    }

    private static func collapseConsecutiveBlankLines(_ lines: [String]) -> [String] {
        var collapsed: [String] = []
        var prevBlank = false
        for line in lines {
            let isBlank = line.isEmpty
            if isBlank, prevBlank { continue }
            prevBlank = isBlank
            collapsed.append(line)
        }
        return collapsed
    }

    private static func replaceMatches(in text: String, regex: NSRegularExpression, with replacement: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }
}

// MARK: - SwiftUI blur hook

private struct ImageGenPromptSentenceCaseOnBlurModifier: ViewModifier {
    @Binding var text: String
    var perLine: Bool
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .onChange(of: isFocused) { wasFocused, nowFocused in
                if wasFocused, !nowFocused {
                    commitSentenceCase()
                }
            }
    }

    private func commitSentenceCase() {
        let normalized = ImageGenPromptSentenceCase.normalized(text, perLine: perLine)
        if normalized != text {
            text = normalized
        }
    }
}

extension View {
    /// Apply Python ``install_image_gen_prompt_sentence_case_on_blur`` when the field loses focus.
    func imageGenPromptSentenceCaseOnBlur(_ text: Binding<String>, perLine: Bool = false) -> some View {
        modifier(ImageGenPromptSentenceCaseOnBlurModifier(text: text, perLine: perLine))
    }
}
