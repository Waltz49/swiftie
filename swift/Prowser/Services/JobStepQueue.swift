import Foundation

/// Port of `imagegen_plugins/job_step_queue.py`.
enum JobStepQueue {
    static let stepVersion = 1
    static let seriesContinuousCopies = 51
    static let chainStateKey = "chain_state"
    static let continuousModeKey = "continuous_mode"
    static let continuousTemplateKey = "continuous_template"
    static let fluxPromptAIJobKey = "flux_prompt_ai_job"

    static func newStepID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
    }

    static func stepValues(_ step: [String: Any]?) -> [String: Any] {
        guard let step, let raw = step["values"] as? [String: Any] else { return [:] }
        return raw
    }

    static func stepNeedsAI(_ step: [String: Any]?) -> Bool {
        guard let step else { return false }
        return step["needs_ai"] as? Bool ?? false
    }

    static func mergeStepIntoValues(_ step: [String: Any]) -> [String: Any] {
        var out = stepValues(step)
        if let meta = step[fluxPromptAIJobKey] as? [String: Any] {
            out[fluxPromptAIJobKey] = meta
        }
        if step["series_refinement"] as? Bool == true {
            out["series_refinement"] = true
        }
        if step["series_prompt_refinement"] as? Bool == true {
            out["series_prompt_refinement"] = true
        }
        return out
    }

    static func isSeriesContinuousCopies(_ copies: Int) -> Bool {
        copies >= seriesContinuousCopies
    }

    static func normalizeCopies(_ raw: Any) -> Int {
        let value = (raw as? Int) ?? Int("\(raw)") ?? 1
        let clamped = max(1, min(50, value))
        return clamped >= seriesContinuousCopies ? seriesContinuousCopies : clamped
    }

    static func pendingStepCount(_ doc: [String: Any]?) -> Int {
        guard let doc, let steps = doc["steps"] as? [[String: Any]] else { return 0 }
        return steps.count
    }

    static func buildPendingJobDoc(
        jobID: String,
        pluginID: String,
        function: String,
        steps: [[String: Any]],
        fullPrompt: String,
        thumbnailPaths: [String],
        stepsDone: Int = 0,
        continuousMode: Bool = false,
        continuousTemplate: [String: Any]? = nil
    ) -> [String: Any] {
        var doc: [String: Any] = [
            "version": stepVersion,
            "job_id": jobID,
            "plugin_id": pluginID,
            "function": function,
            "display": [
                "full_prompt": fullPrompt,
                "thumbnail_paths": thumbnailPaths,
            ],
            "steps_done": max(0, stepsDone),
            "steps": steps,
        ]
        if continuousMode {
            doc[continuousModeKey] = true
        }
        if let continuousTemplate {
            doc[continuousTemplateKey] = continuousTemplate
        }
        return doc
    }

    static func buildRunningJobDoc(
        jobID: String,
        pluginID: String,
        function: String,
        step: [String: Any],
        outputPath: String,
        fullPrompt: String,
        thumbnailPaths: [String]
    ) -> [String: Any] {
        [
            "version": stepVersion,
            "job_id": jobID,
            "plugin_id": pluginID,
            "function": function,
            "output_path": outputPath,
            "display": [
                "full_prompt": fullPrompt,
                "thumbnail_paths": thumbnailPaths,
            ],
            "step": step,
        ]
    }

    static func popNextStep(from doc: inout [String: Any]) -> [String: Any]? {
        guard var steps = doc["steps"] as? [[String: Any]], !steps.isEmpty else { return nil }
        let step = steps.removeFirst()
        doc["steps"] = steps
        let done = (doc["steps_done"] as? Int) ?? 0
        doc["steps_done"] = done + 1
        return step
    }
}
