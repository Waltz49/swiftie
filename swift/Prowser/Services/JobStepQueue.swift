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

    static func promptFromStatusView(_ view: QueueJobStatusView?) -> String {
        guard let view else { return "" }
        for row in view.rows {
            if case .prompt(_, let value) = row {
                return value
            }
        }
        return ""
    }

    static func resolvedFullPrompt(
        stored: String,
        values: [String: Any],
        steps: [[String: Any]],
        statusView: QueueJobStatusView?
    ) -> String {
        let candidates = [
            stored,
            values["prompt"] as? String ?? "",
            steps.first.map { mergeStepIntoValues($0)["prompt"] as? String ?? "" } ?? "",
            promptFromStatusView(statusView),
        ]
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return candidate
            }
        }
        return ""
    }

    static func ensureStepsHavePrompt(
        _ steps: [[String: Any]],
        prompt: String,
        jobValues: [String: Any]
    ) -> [[String: Any]] {
        let resolved = resolvedFullPrompt(stored: prompt, values: jobValues, steps: steps, statusView: nil)
        let trimmed = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return steps }
        return steps.map { step in
            var copy = step
            var vals = stepValues(copy)
            if (vals["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                vals["prompt"] = resolved
                copy["values"] = vals
            }
            return copy
        }
    }

    /// Merge step values and restore prompt from job/display when step snapshot omitted it.
    static func generationValues(
        from step: [String: Any],
        jobValues: [String: Any],
        displayFullPrompt: String,
        statusViewPrompt: String = ""
    ) -> [String: Any] {
        var values = mergeStepIntoValues(step)
        let stepPrompt = (values["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !stepPrompt.isEmpty {
            return values
        }
        for candidate in [displayFullPrompt, jobValues["prompt"] as? String ?? "", statusViewPrompt] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                values["prompt"] = candidate
                return values
            }
        }
        return values
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
        return step
    }

    static func prependPendingStep(doc: [String: Any], step: [String: Any]) -> [String: Any] {
        let steps = doc["steps"] as? [[String: Any]] ?? []
        var out = doc
        out["steps"] = [step] + steps
        return out
    }

    static func syncChainStateToPendingDoc(
        _ doc: [String: Any]?,
        outputPath: String = "",
        prompt: String = "",
        priorValues: [String: Any]? = nil
    ) -> [String: Any]? {
        guard let doc else { return nil }
        var out = doc
        var chain: [String: Any] = [:]
        if !outputPath.isEmpty {
            chain["last_output_path"] = outputPath
        }
        if !prompt.isEmpty {
            chain["last_prompt"] = prompt
        }
        if let priorValues, !priorValues.isEmpty {
            chain["last_values"] = priorValues
        }
        if chain.isEmpty {
            out.removeValue(forKey: chainStateKey)
        } else {
            out[chainStateKey] = chain
        }
        return out
    }

    static func restoreChainStateFromPendingDoc(_ doc: [String: Any]?) -> (outputPath: String, prompt: String, values: [String: Any]) {
        guard let doc, let chain = doc[chainStateKey] as? [String: Any] else {
            return ("", "", [:])
        }
        let outputPath = chain["last_output_path"] as? String ?? ""
        let prompt = chain["last_prompt"] as? String ?? ""
        let values = chain["last_values"] as? [String: Any] ?? [:]
        return (outputPath, prompt, values)
    }

    static func pendingDocIsContinuous(_ doc: [String: Any]?, runningStep: [String: Any]? = nil) -> Bool {
        if let doc, doc[continuousModeKey] as? Bool == true {
            return true
        }
        if let doc, doc[continuousTemplateKey] as? [String: Any] != nil {
            return true
        }
        if let runningStep {
            let copies = stepValues(runningStep)["copies"] as? Int ?? Int("\(stepValues(runningStep)["copies"] ?? "")") ?? 0
            if isSeriesContinuousCopies(copies) { return true }
        }
        if let steps = doc?["steps"] as? [[String: Any]] {
            for step in steps {
                let copies = stepValues(step)["copies"] as? Int ?? Int("\(stepValues(step)["copies"] ?? "")") ?? 0
                if isSeriesContinuousCopies(copies) { return true }
            }
        }
        return false
    }
}
