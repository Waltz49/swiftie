import Foundation

/// Port of ``chat_prompt_grammar.format_chat_prompt_text_for_save``.
enum ChatPromptFormatting {
    private static let terminalPunctuation: Set<Character> = ["?", "!", ".", ":"]

    static func formatForSave(_ text: String) -> String {
        var core = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if core.isEmpty { return text }
        if let last = core.last, !terminalPunctuation.contains(last) {
            core += "."
        }
        return core + " "
    }
}
