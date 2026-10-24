import Foundation

/// Dialog vs worker prompt boundaries (Python ``imagegen_values_for_dialog_save`` / ``get_prompt_text``).
enum ImageGenDialogPromptPersistence {
    /// Prompt text to show when editing a queued job — raw stored values, not worker payload exits.
    static func primeEditorPrompt(jobValues: [String: Any], fullPrompt: String = "") -> String {
        let fromValues = jobValues["prompt"] as? String ?? ""
        let trimmed = fromValues.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? fullPrompt : fromValues
        return AIPromptExitService.restoreLoremPlaceholdersForDialog(base)
    }
}
