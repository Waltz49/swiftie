import Foundation

/// Port of ``lora_trigger_prompt_guard`` for snapshotted Swift worker payloads.
enum ImageGenLoraTriggerPromptGuard {
    static func applyForRun(_ values: inout [String: Any]) {
        let prompt = (values["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        values["prompt"] = augmentPromptWithMissingLoraTriggers(prompt: prompt, values: values)
    }

    static func augmentPromptWithMissingLoraTriggers(
        prompt: String,
        values: [String: Any]
    ) -> String {
        let promptS = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let missing = missingLoraTriggerWords(prompt: promptS, values: values)
        if missing.isEmpty {
            return promptS
        }
        return formatPromptWithTriggers(promptS, triggerBlock: missing.joined(separator: "\n"))
    }

    private static func missingLoraTriggerWords(prompt: String, values: [String: Any]) -> [String] {
        let triggers = knownTriggerWords(values: values)
        var missing: [String] = []
        var seen = Set<String>()
        for trigger in triggers {
            let key = trigger.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            if !promptContainsLoraTrigger(prompt: prompt, trigger: trigger) {
                missing.append(trigger)
            }
        }
        return missing
    }

    private static func knownTriggerWords(values: [String: Any]) -> [String] {
        if values["_job_values_snapshotted"] as? Bool == true,
           let snap = values["mflux_lora_trigger_words"] as? [Any] {
            return snap.compactMap { item in
                let text = String(describing: item).trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
        }
        return []
    }

    private static func promptContainsLoraTrigger(prompt: String, trigger: String) -> Bool {
        let promptS = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let triggerS = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        if triggerS.isEmpty { return true }
        if promptS.isEmpty { return false }
        if triggerS.contains(" ") {
            return promptS.range(of: triggerS, options: .caseInsensitive) != nil
        }
        let pattern = "(?<!\\w)" + NSRegularExpression.escapedPattern(for: triggerS) + "(?!\\w)"
        return promptS.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func formatPromptWithTriggers(_ promptS: String, triggerBlock: String) -> String {
        let block = triggerBlock.trimmingCharacters(in: .whitespacesAndNewlines)
        if block.isEmpty { return promptS }
        if promptS.isEmpty { return block }
        // TRIGGER_POSITION = 0 (top) in thumbnails.thumbnail_constants
        return "\(block)\n\n\(promptS)"
    }
}
