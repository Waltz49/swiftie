import Foundation

/// Port of `workers/model_tasks_worker.py` flux prompt message builders.
@MainActor
enum FluxPromptMessages {
    private static let emptyUserText =
        "The prompt field is empty. Suggest a strong photographic FLUX prompt "
        + "appropriate for this task."

    static func systemMessage(
        taskKind: String,
        maxWords: Int,
        withImage: Bool,
        imageCount: Int
    ) -> String {
        let fluxRealism =
            "You write \(maxWords) word prompts for FLUX diffusion models. "
            + "Do NOT add conversation, titles, labels, quotes, markdown, or explanations. "
        let task = taskInstructions[taskKind] ?? taskInstructions["create"] ?? ""
        let base = "\(fluxRealism) \(task)".trimmingCharacters(in: .whitespacesAndNewlines)
        guard withImage else { return base }
        let photoPhrase = imageCount > 1 ? "\(imageCount) reference photographs" : "a reference photograph"
        return """
        \(base) The user message includes \(photoPhrase). Use them as visual context, but treat the user's text as the edit goal—refine their instructions into the FLUX prompt; do not ignore them in favor of a generic image description.
        """.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func userMessage(userPrompt: String, withImage: Bool) -> String {
        let userText = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if withImage {
            let prefix =
                "Create a new image description based on the incoming image(s) and the user's instructions."
            if userText.isEmpty {
                return prefix
            }
            return "\(prefix)\n\nUser instructions:\n\(userText)"
        }
        if !userText.isEmpty { return userText }
        return emptyUserText
    }

    static func resolvedSystemPrompt(
        taskKind: String,
        config: AppConfig,
        override: String?,
        withImage: Bool,
        imageCount: Int
    ) -> String {
        let trimmedOverride = override?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedOverride.isEmpty { return trimmedOverride }
        let maxWords = config.int(forKey: "caption_max_words", default: 200)
        return systemMessage(taskKind: taskKind, maxWords: maxWords, withImage: withImage, imageCount: imageCount)
    }

    private static let taskInstructions: [String: String] = [
        "create": "",
        "edit": "",
        "expand": "",
        "infill": "",
    ]
}
