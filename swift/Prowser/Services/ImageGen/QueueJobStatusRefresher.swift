import Foundation

/// Fingerprint queue card status inputs so payload + builder can be skipped when unchanged.
@MainActor
enum QueueJobStatusRefresher {
    private static var inputsFingerprintByJobID: [String: String] = [:]

    #if DEBUG
    private(set) static var buildSkippedBecauseFingerprintCountForTesting = 0

    static func resetTestingCounters() {
        buildSkippedBecauseFingerprintCountForTesting = 0
    }
    #endif

    static func clearFingerprint(jobID: String) {
        inputsFingerprintByJobID.removeValue(forKey: jobID)
    }

    static func clearAllFingerprints() {
        inputsFingerprintByJobID.removeAll()
    }

    /// Keys that affect ``QueueJobStatusBuilder`` / reference thumbnails (not live step/elapsed).
    private static let valuesFingerprintKeys: [String] = [
        "prompt", "negative_prompt", "hf_model_id", "model", "lora", "lora_scale",
        "width", "height", "steps", "guidance", "seed", "random_seed", "copies",
        "series_prompt_refinement", "image_ref", "mask_ref", "source_image", "fill_image",
        JobStepQueue.fluxPromptAIJobKey,
    ]

    static func inputsFingerprint(
        pluginID: String,
        function: String,
        values: [String: Any],
        copiesTotal: Int,
        pluginUnavailable: Bool,
        storedFullPrompt: String,
        loraLabel: String?,
        hasFluxAI: Bool
    ) -> String {
        var parts: [String] = [
            pluginID,
            function,
            String(copiesTotal),
            pluginUnavailable ? "1" : "0",
            hasFluxAI ? "1" : "0",
            storedFullPrompt,
            loraLabel ?? "",
        ]
        for key in valuesFingerprintKeys {
            if let value = values[key] {
                parts.append("\(key)=\(stableValueDescription(value))")
            }
        }
        return parts.joined(separator: "|")
    }

    static func shouldSkipStatusRebuild(jobID: String, fingerprint: String, statusView: QueueJobStatusView?) -> Bool {
        guard let statusView, !statusView.isEmpty else { return false }
        guard inputsFingerprintByJobID[jobID] == fingerprint else { return false }
        #if DEBUG
        buildSkippedBecauseFingerprintCountForTesting += 1
        #endif
        return true
    }

    static func recordFingerprint(jobID: String, fingerprint: String) {
        inputsFingerprintByJobID[jobID] = fingerprint
    }

    private static func stableValueDescription(_ value: Any) -> String {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        case let bool as Bool:
            return bool ? "true" : "false"
        case let array as [Any]:
            return array.map { stableValueDescription($0) }.joined(separator: ",")
        case let dict as [String: Any]:
            return dict.keys.sorted().map { "\($0):\(stableValueDescription(dict[$0]!))" }.joined(separator: ";")
        default:
            return String(describing: value)
        }
    }
}
