import Foundation

/// Dialog vs worker prompt boundaries (Python ``imagegen_values_for_dialog_save`` / ``get_prompt_text``).
enum ImageGenDialogPromptPersistence {
    private static let dialogLeakedJobQueueKeys = ["series_refinement", "series_prompt_refinement"]

    /// Prompt text to show when editing a queued job — raw stored values, not worker payload exits.
    static func primeEditorPrompt(jobValues: [String: Any], fullPrompt: String = "") -> String {
        let fromValues = jobValues["prompt"] as? String ?? ""
        let trimmed = fromValues.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? fullPrompt : fromValues
        var result = AIPromptExitService.restoreLoremPlaceholdersForDialog(base)
        result = ImageGenPromptTextEncoding.repairUTF8BytesMisinterpretedAsLatin1(result)
        return result
    }

    /// Persist dialog settings using the user's raw prompt text (Python ``imagegen_values_for_dialog_save``).
    static func valuesForDialogSave(
        submitValues: [String: Any],
        dialogPrompt: String,
        negativePrompt: String? = nil
    ) -> [String: Any] {
        var out = submitValues
        for key in dialogLeakedJobQueueKeys {
            out.removeValue(forKey: key)
        }
        out["prompt"] = dialogPrompt
        if let negativePrompt {
            out["negative_prompt"] = negativePrompt
        }
        return out
    }
}
