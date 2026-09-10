import Foundation

/// Swift helpers mirroring `image_gen_persistence.py` imagegen settings keys.
@MainActor
enum ImageGenPersistence {
    private static func imagegenBlock(config: AppConfig) -> [String: Any] {
        config.rawSettings()["imagegen"] as? [String: Any] ?? [:]
    }

    private static func mutateImagegen(config: AppConfig, _ mutate: (inout [String: Any]) -> Void) {
        var imagegen = imagegenBlock(config: config)
        mutate(&imagegen)
        config.updateSetting("imagegen", value: imagegen)
    }

    static func closeDialogOnGenerate(config: AppConfig) -> Bool {
        imagegenBlock(config: config)["close_dialog_on_generate"] as? Bool ?? false
    }

    static func setCloseDialogOnGenerate(_ enabled: Bool, config: AppConfig) {
        mutateImagegen(config: config) { $0["close_dialog_on_generate"] = enabled }
    }

    static func passImageToAI(config: AppConfig) -> Bool {
        imagegenBlock(config: config)["pass_image_to_ai_with_prompt"] as? Bool ?? false
    }

    static func setPassImageToAI(_ enabled: Bool, config: AppConfig) {
        mutateImagegen(config: config) { $0["pass_image_to_ai_with_prompt"] = enabled }
    }

    static func fluxPromptJobWithGenerate(config: AppConfig) -> Bool {
        imagegenBlock(config: config)["flux_prompt_job_with_generate"] as? Bool ?? false
    }

    static func setFluxPromptJobWithGenerate(_ enabled: Bool, config: AppConfig) {
        mutateImagegen(config: config) { $0["flux_prompt_job_with_generate"] = enabled }
    }

    static func fluxSystemPromptText(config: AppConfig) -> String {
        imagegenBlock(config: config)["flux_prompt_system_prompt"] as? String ?? ""
    }

    static func fluxSystemPromptExpanded(config: AppConfig) -> Bool {
        imagegenBlock(config: config)["flux_prompt_system_prompt_expanded"] as? Bool ?? false
    }

    static func saveFluxSystemPrompt(text: String, expanded: Bool, config: AppConfig) {
        mutateImagegen(config: config) {
            $0["flux_prompt_system_prompt"] = text
            $0["flux_prompt_system_prompt_expanded"] = expanded
        }
    }

    static func snapshotSignature(_ values: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "\(values.count)"
        }
        return text
    }

    static func snapshotsEqual(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        snapshotSignature(lhs) == snapshotSignature(rhs)
    }
}
