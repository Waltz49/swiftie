import Foundation

/// Swift-side prompt rules before Python `build_worker_payload` (prefix/postfix, exits).
enum ImageGenMfluxPayloadBuilder {
    /// Python ``apply_image_ai_exit`` (prefix/postfix + exit script only).
    @MainActor
    static func applyImageAIExitForRun(prompt: String, config: AppConfig) -> String {
        let withRules = PrefixPostfixStore.applyRules(prompt, forImages: true, config: config)
        return AIPromptExitService.applyImageAIExit(withRules, config: config)
    }

    @MainActor
    static func applyImagePromptRules(values: [String: Any], config: AppConfig) -> [String: Any] {
        var out = values
        guard let raw = out["prompt"] as? String else { return out }
        let prompt = applyImageAIExitForRun(
            prompt: ImageGenPromptSentenceCase.normalized(raw),
            config: config
        )
        out["prompt"] = prompt
        return out
    }
}
