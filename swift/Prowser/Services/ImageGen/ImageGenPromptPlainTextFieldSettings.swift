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

    /// Replace entire field text from SwiftUI/bindings without leaving undo stack entries sized for prior content.
    static func replaceProgrammaticFullText(
        _ newText: String,
        on textView: NSTextView,
        preservingSelectionFrom selected: NSRange
    ) {
        let len = ImageGenPromptTextEncoding.utf16Length(of: newText)
        if textView.string == newText {
            if selected.location <= len {
                textView.setSelectedRange(selected)
            } else {
                textView.setSelectedRange(NSRange(location: len, length: 0))
            }
            return
        }
        let priorAllowsUndo = textView.allowsUndo
        textView.allowsUndo = false
        textView.string = newText
        textView.undoManager?.removeAllActions()
        textView.allowsUndo = priorAllowsUndo
        if selected.location <= len {
            textView.setSelectedRange(selected)
        } else {
            textView.setSelectedRange(NSRange(location: len, length: 0))
        }
    }
}
