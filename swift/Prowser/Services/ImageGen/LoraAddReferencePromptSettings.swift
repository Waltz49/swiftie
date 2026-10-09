import Foundation

/// Last reference prompt for Add LoRA (Python ``load_persisted_lora_add_reference_prompt``).
@MainActor
enum LoraAddReferencePromptSettings {
    static let defaultPrompt = "A woman riding a bycicle along a path."
    private static let loraAddKey = "lora_add"
    private static let referencePromptKey = "reference_prompt"

    static func load(config: AppConfig) -> String {
        let imagegen = config.rawSettings()["imagegen"] as? [String: Any] ?? [:]
        let loraAdd = imagegen[loraAddKey] as? [String: Any] ?? [:]
        let text = (loraAdd[referencePromptKey] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? defaultPrompt : text
    }

    static func save(_ referencePrompt: String, config: AppConfig) {
        let trimmed = referencePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? defaultPrompt : trimmed
        var imagegen = config.rawSettings()["imagegen"] as? [String: Any] ?? [:]
        var loraAdd = imagegen[loraAddKey] as? [String: Any] ?? [:]
        loraAdd[referencePromptKey] = value
        imagegen[loraAddKey] = loraAdd
        config.updateSetting("imagegen", value: imagegen)
    }
}
