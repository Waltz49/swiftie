import Foundation

/// Port of `imagegen_plugins/job_step_queue.py`.
enum JobStepQueue {
    static let stepVersion = 1
    static let seriesContinuousCopies = 51
    /// Port of ``ImageGenController._COPIES_MAX``.
    static let copiesMax = 200
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
        mergeMissingLoraFields(from: jobValues, into: &values)
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
        let clamped = max(1, min(copiesMax, value))
        if isSeriesContinuousCopies(clamped) {
            return seriesContinuousCopies
        }
        return clamped
    }

    static func materializeSteps(
        pluginID: String,
        templateValues: [String: Any],
        copiesTotal: Int
    ) throws -> [[String: Any]] {
        guard ImageGenPluginCatalog.plugin(pluginID: pluginID) != nil else {
            throw ImageGenRegistryError.unknownPlugin(pluginID)
        }
        var count = max(1, copiesTotal)
        if count > seriesContinuousCopies - 1 {
            count = seriesContinuousCopies
        }
        let hasAI = hasFluxPromptAIJob(templateValues)
        var steps: [[String: Any]] = []
        for _ in 0..<count {
            var values = templateValues
            values["copies"] = count
            // Python ``materialize_steps``: Job AI refines before every copy; otherwise
            // text series refinement marks the step.
            let needsAI = hasAI || values["series_prompt_refinement"] as? Bool == true
            steps.append(copyStep(from: values, needsAI: needsAI))
        }
        return steps
    }

    /// Port of ``materialize_pending_steps_from_update`` (series + / Update remaining copies).
    static func materializePendingStepsFromUpdate(
        pluginID: String,
        templateValues: [String: Any],
        count: Int
    ) throws -> [[String: Any]] {
        let n = max(0, count)
        if n <= 0 { return [] }
        guard ImageGenPluginCatalog.plugin(pluginID: pluginID) != nil else {
            throw ImageGenRegistryError.unknownPlugin(pluginID)
        }
        let hasAI = hasFluxPromptAIJob(templateValues)
        var steps: [[String: Any]] = []
        for _ in 0..<n {
            steps.append(copyStep(from: templateValues, needsAI: hasAI))
        }
        return steps
    }

    /// Port of ``_stamp_series_copies_on_steps``.
    static func stampSeriesCopiesOnSteps(_ steps: inout [[String: Any]], copies: Int) {
        for index in steps.indices {
            var values = stepValues(steps[index])
            values["copies"] = copies
            steps[index]["values"] = jsonSafeDict(values)
        }
    }

    static func hasFluxPromptAIJob(_ values: [String: Any]) -> Bool {
        values[fluxPromptAIJobKey] is [String: Any]
    }

    /// Append one generation step from a continuous-series template (port of ``_append_continuous_pending_step``).
    static func appendContinuousStep(to doc: [String: Any], templateStep: [String: Any]) -> [String: Any] {
        let values = mergeStepIntoValues(templateStep)
        let needsAI = stepNeedsAI(templateStep) || hasFluxPromptAIJob(values)
        let step = copyStep(from: values, needsAI: needsAI)
        return appendPendingStep(doc: doc, step: step)
    }

    private static func copyStep(from values: [String: Any], needsAI: Bool) -> [String: Any] {
        var step: [String: Any] = [
            "step_id": newStepID(),
            "values": jsonSafeDict(values),
            "needs_ai": needsAI,
        ]
        if let meta = values[fluxPromptAIJobKey] as? [String: Any] {
            step[fluxPromptAIJobKey] = meta
        }
        if values["series_refinement"] as? Bool == true {
            step["series_refinement"] = true
        }
        if values["series_prompt_refinement"] as? Bool == true {
            step["series_prompt_refinement"] = true
        }
        return step
    }

    private static func mergeMissingLoraFields(from jobValues: [String: Any], into values: inout [String: Any]) {
        for key in ImageGenLoraWorkerPayloadEnrich.mergeKeys {
            if values[key] != nil { continue }
            if let value = jobValues[key] {
                values[key] = value
            }
        }
        if values["mflux_lora_stack"] == nil, let stack = jobValues["mflux_lora_stack"] {
            values["mflux_lora_stack"] = stack
        }
        if values["mflux_lora"] == nil, let single = jobValues["mflux_lora"] {
            values["mflux_lora"] = single
        }
    }

    private static func jsonSafeDict(_ values: [String: Any]) -> [String: Any] {
        // JSONSerialization-safe subset (NSNumber, String, Bool, arrays, dicts).
        var out: [String: Any] = [:]
        for (key, value) in values {
            if JSONSerialization.isValidJSONObject([key: value]) {
                out[key] = value
            } else if let url = value as? URL {
                out[key] = url.path
            }
        }
        return out
    }

    static func pendingStepCount(_ doc: [String: Any]?) -> Int {
        guard let doc, let steps = doc["steps"] as? [[String: Any]] else { return 0 }
        return steps.count
    }

    static func parseHeldFromDoc(_ doc: [String: Any]?) -> Bool {
        guard let doc else { return false }
        return doc["held"] as? Bool ?? false
    }

    static func applyHeldToDoc(_ doc: [String: Any], held: Bool) -> [String: Any] {
        var out = doc
        if held {
            out["held"] = true
        } else {
            out.removeValue(forKey: "held")
        }
        return out
    }

    static func applyJobNumberToDoc(_ doc: [String: Any], jobNumber: Int?) -> [String: Any] {
        var out = doc
        if let jobNumber, (1...ImageGenJobNumber.jobNumberMax).contains(jobNumber) {
            out["job_number"] = jobNumber
        }
        return out
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
        continuousTemplate: [String: Any]? = nil,
        jobNumber: Int? = nil,
        held: Bool = false
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
        doc = applyJobNumberToDoc(doc, jobNumber: jobNumber)
        return applyHeldToDoc(doc, held: held)
    }

    static func buildRunningJobDoc(
        jobID: String,
        pluginID: String,
        function: String,
        step: [String: Any],
        outputPath: String,
        fullPrompt: String,
        thumbnailPaths: [String],
        jobNumber: Int? = nil,
        held: Bool = false
    ) -> [String: Any] {
        var doc: [String: Any] = [
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
        doc = applyJobNumberToDoc(doc, jobNumber: jobNumber)
        return applyHeldToDoc(doc, held: held)
    }

    /// Port of ``active_job_step_docs_for_persist`` (`job_step_queue.py`).
    static func activeJobStepDocsForPersist(
        jobID: String,
        pluginID: String,
        function: String,
        runningStep: [String: Any]?,
        pendingDoc: [String: Any]?,
        outputPath: String,
        fullPrompt: String,
        thumbnailPaths: [String],
        jobNumber: Int?,
        held: Bool
    ) -> (running: [String: Any]?, pending: [String: Any]?) {
        let heldOnPending = parseHeldFromDoc(pendingDoc) || held
        var runningDoc: [String: Any]?
        if let runningStep {
            runningDoc = buildRunningJobDoc(
                jobID: jobID,
                pluginID: pluginID,
                function: function,
                step: runningStep,
                outputPath: outputPath,
                fullPrompt: fullPrompt,
                thumbnailPaths: thumbnailPaths,
                jobNumber: jobNumber,
                held: heldOnPending
            )
        }
        var pendingOut = pendingDoc
        if pendingOut == nil, runningStep == nil {
            return (nil, nil)
        }
        if pendingOut == nil {
            pendingOut = buildPendingJobDoc(
                jobID: jobID,
                pluginID: pluginID,
                function: function,
                steps: [],
                fullPrompt: fullPrompt,
                thumbnailPaths: thumbnailPaths,
                jobNumber: jobNumber,
                held: heldOnPending
            )
        } else if jobNumber != nil {
            pendingOut = applyJobNumberToDoc(pendingOut!, jobNumber: jobNumber)
        }
        return (runningDoc, pendingOut)
    }

    static func fluxPromptAIJobMeta(_ step: [String: Any]?) -> [String: Any]? {
        guard let step else { return nil }
        if let meta = step[fluxPromptAIJobKey] as? [String: Any] { return meta }
        return stepValues(step)[fluxPromptAIJobKey] as? [String: Any]
    }

    /// Port of ``prepare_step_ai_launch``.
    static func prepareStepAILaunch(_ step: inout [String: Any]) -> Bool {
        guard var meta = fluxPromptAIJobMeta(step) else { return false }
        var values = stepValues(step)
        let prompt = (values["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            meta["user_prompt"] = prompt
            step[fluxPromptAIJobKey] = meta
            values[fluxPromptAIJobKey] = meta
            step["values"] = jsonSafeDict(values)
        }
        return fluxPromptAIJobMeta(step) != nil
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

    static func appendPendingStep(doc: [String: Any], step: [String: Any]) -> [String: Any] {
        let steps = doc["steps"] as? [[String: Any]] ?? []
        var out = doc
        out["steps"] = steps + [step]
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
