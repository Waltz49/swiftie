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
}
