import Foundation

/// Swift-side prompt rules before Python `build_worker_payload` (prefix/postfix, exits).
enum ImageGenMfluxPayloadBuilder {
    @MainActor
    static func applyImagePromptRules(values: [String: Any], config: AppConfig) -> [String: Any] {
        var out = values
        guard let raw = out["prompt"] as? String else { return out }
        var prompt = ImageGenPromptSentenceCase.normalized(raw)
        prompt = PrefixPostfixStore.applyRules(prompt, forImages: true, config: config)
        prompt = AIPromptExitService.applyImageAIExit(prompt, config: config)
        out["prompt"] = prompt
        return out
    }
}
