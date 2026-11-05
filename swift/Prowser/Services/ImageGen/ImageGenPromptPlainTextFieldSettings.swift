import AppKit

/// Shared ``NSTextView`` options for multiline prompt / comment fields (full Unicode input).
enum ImageGenPromptPlainTextFieldSettings {
    static func applyUnicodePlainTextInputDefaults(to textView: NSTextView) {
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
    }

    /// macOS Text Replacements (System Settings → Keyboard → Text Replacements).
    static func applyAutomaticTextReplacementEnabled(to textView: NSTextView) {
        textView.isAutomaticTextReplacementEnabled = true
    }
}
