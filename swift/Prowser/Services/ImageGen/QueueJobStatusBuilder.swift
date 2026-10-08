import Foundation

struct QueueJobStatusBuildResult {
    var statusView: QueueJobStatusView
    var thumbnailPaths: [String]
    var fullPrompt: String
    var referencesInvalid: Bool
}

/// Native job card status (port of ``build_queue_job_status_view``).
enum QueueJobStatusBuilder {
    private static let quantLabel = "Q:"
    private static let promptTruncate = 400

    static func build(
        pluginID: String,
        function: String,
        values: [String: Any],
        copiesTotal: Int,
        payload: [String: Any]? = nil,
        pluginUnavailable: Bool = false,
        running: Bool = false,
        omitLiveStepsRow: Bool = false,
        withAI: Bool = false,
        step: Int? = nil,
        stepTotal: Int? = nil,
        elapsedSeconds: Double? = nil,
        estimateSeconds: Double? = nil,
        loraLabel: String? = nil
    ) -> QueueJobStatusBuildResult {
        let thumbPaths = JobCardThumbnailPaths.paths(pluginID: pluginID, values: values)
        let refsInvalid = JobCardThumbnailPaths.referencesInvalid(pluginID: pluginID, values: values)

        if pluginUnavailable || ImageGenPluginCatalog.plugin(pluginID: pluginID) == nil {
            return QueueJobStatusBuildResult(
                statusView: unavailableView(pluginID: pluginID, function: function, values: values, copiesTotal: copiesTotal),
                thumbnailPaths: thumbPaths,
                fullPrompt: resolvedFullPrompt(values: values),
                referencesInvalid: refsInvalid
            )
        }

        if withAI {
            let view = buildAIStageView(
                pluginID: pluginID,
                values: values,
                running: running,
                step: step,
                stepTotal: stepTotal,
                elapsedSeconds: elapsedSeconds,
                estimateSeconds: estimateSeconds
            )
            return QueueJobStatusBuildResult(
                statusView: view,
                thumbnailPaths: thumbPaths,
                fullPrompt: resolvedFullPrompt(values: values),
                referencesInvalid: refsInvalid
            )
        }

        guard let plugin = ImageGenPluginCatalog.plugin(pluginID: pluginID) else {
            return QueueJobStatusBuildResult(
                statusView: unavailableView(pluginID: pluginID, function: function, values: values, copiesTotal: copiesTotal),
                thumbnailPaths: thumbPaths,
                fullPrompt: resolvedFullPrompt(values: values),
                referencesInvalid: refsInvalid
            )
        }

        let fields = collectFields(plugin: plugin, values: values, payload: payload, loraLabel: loraLabel)
        let stepsValue = stepsDisplay(fieldsSteps: fields.steps, step: step, stepTotal: stepTotal)
        let showTiming = step != nil && stepTotal != nil && (stepTotal ?? 0) > 0 && elapsedSeconds != nil

        var rows = generationRows(
            fields: fields,
            stepsValue: stepsValue,
            elapsedSeconds: showTiming ? elapsedSeconds : nil,
            estimateSeconds: showTiming ? estimateSeconds : nil,
            omitLiveStepsRow: omitLiveStepsRow
        )

        if copiesTotal > 1 {
            let base = seriesQueuedValue(count: copiesTotal)
            rows.append(.labelValue(label: "Copies:", value: formatSeriesLine(base: base, values: values)))
        }

        var title = taskMenuTitle(pipelineID: plugin.pipelineID)
        if withAI || hasFluxPromptAIJob(values) {
            title = jobTitleWithAISuffix(title)
        }

        var viewRows: [QueueStatusRowKind] = []
        if !title.isEmpty {
            viewRows.append(.title(title, running: running))
        }
        viewRows.append(contentsOf: rows)

        return QueueJobStatusBuildResult(
            statusView: QueueJobStatusView(rows: viewRows, running: running),
            thumbnailPaths: thumbPaths,
            fullPrompt: fields.prompt.isEmpty ? resolvedFullPrompt(values: values) : fields.prompt,
            referencesInvalid: refsInvalid
        )
    }

    // MARK: - Unavailable

    private static func unavailableView(
        pluginID: String,
        function: String,
        values: [String: Any],
        copiesTotal: Int
    ) -> QueueJobStatusView {
        let prompt = normalizePromptForDisplay(values["prompt"] as? String ?? "")
        let preview = prompt.count > 48 ? String(prompt.prefix(48)) + "…" : prompt
        return QueueJobStatusView(rows: [
            .unavailable(
                heading: "Unavailable model (\(function) / \(pluginID))",
                copiesLine: "Copies: \(copiesTotal)",
                promptLine: "Prompt: \(preview.isEmpty ? "—" : preview)"
            ),
        ])
    }

    // MARK: - AI stage

    private static func buildAIStageView(
        pluginID: String,
        values: [String: Any],
        running: Bool,
        step: Int?,
        stepTotal: Int?,
        elapsedSeconds: Double?,
        estimateSeconds: Double?
    ) -> QueueJobStatusView {
        guard let plugin = ImageGenPluginCatalog.plugin(pluginID: pluginID) else {
            return QueueJobStatusView.degradedFallback(prompt: values["prompt"] as? String ?? "", copiesTotal: 1)
        }
        let pipeline = ImageGenPipelineModeMetadata.mode(pipelineID: plugin.pipelineID)
        let title = jobTitleWithAISuffix(taskMenuTitle(pipelineID: plugin.pipelineID))
        var rows: [QueueStatusRowKind] = []

        let aiPrompt = normalizePromptForDisplay(fluxPromptAIUserPrompt(values))
        if !aiPrompt.isEmpty {
            rows.append(.prompt(label: pipeline.promptStatusLabel, value: aiPrompt))
        }

        let aiSteps = stepsDisplay(fieldsSteps: "", step: step, stepTotal: stepTotal)
        if !aiSteps.isEmpty, let total = stepTotal, total > 0 {
            let showTiming = step != nil && (step ?? 0) > 0 && elapsedSeconds != nil
            let inline = stepsInlineParts(
                elapsedSeconds: showTiming ? elapsedSeconds : nil,
                estimateSeconds: showTiming ? estimateSeconds : nil
            )
            if inline.isEmpty {
                rows.append(.labelValue(label: "AI:", value: aiSteps))
            } else {
                rows.append(.inline(label: "AI:", primaryValue: aiSteps, inlineParts: inline))
            }
        }
        rows.append(.labelValue(label: "Stage:", value: "AI prompt refinement"))

        return QueueJobStatusView(rows: [.title(title, running: running)] + rows, running: running)
    }

    // MARK: - Fields

    private struct StatusFields {
        var model = ""
        var lora = ""
        var size = ""
        var steps = ""
        var quant = ""
        var prompt = ""
        var promptLabel = "Prompt:"
        var neg = ""
    }

    private static func collectFields(
        plugin: ImageGenPluginDescriptor,
        values: [String: Any],
        payload: [String: Any]? = nil,
        loraLabel: String? = nil
    ) -> StatusFields {
        var effective = values
        if let payload {
            for (key, value) in payload {
                effective[key] = value
            }
        }
        let hf = (effective["hf_model_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = hf.contains("/") ? hf : plugin.hfModelID
        var fields = StatusFields()
        if !modelID.isEmpty {
            fields.model = ImageGenExifCommentFormatting.menuLabelForHFModelId(modelID)
        }
        if let loraLabel, !loraLabel.isEmpty {
            fields.lora = loraLabel
        } else {
            fields.lora = loraLabelForStatus(plugin: plugin, values: effective)
        }
        if let w = intValue(effective["width"]), let h = intValue(effective["height"]), w > 0, h > 0 {
            fields.size = "\(w) x \(h)"
        }
        if let steps = intValue(effective["steps"]) {
            fields.steps = "\(steps)"
        }
        fields.quant = quantizeStatusValue(plugin: plugin, values: effective) ?? ""
        let rawPrompt = (effective["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawPrompt.isEmpty {
            fields.prompt = normalizePromptForDisplay(truncate(rawPrompt))
            fields.promptLabel = ImageGenPipelineModeMetadata.mode(pipelineID: plugin.pipelineID).promptStatusLabel
        }
        let neg = (effective["negative_prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !neg.isEmpty {
            fields.neg = truncate(neg)
        }
        return fields
    }

    private static func generationRows(
        fields: StatusFields,
        stepsValue: String,
        elapsedSeconds: Double?,
        estimateSeconds: Double?,
        omitLiveStepsRow: Bool
    ) -> [QueueStatusRowKind] {
        var rows: [QueueStatusRowKind] = []
        if !fields.model.isEmpty {
            rows.append(.labelValue(label: "Model:", value: fields.model))
        }
        if !fields.lora.isEmpty {
            rows.append(.labelValue(label: "LoRA:", value: fields.lora))
        }
        var quantOnSize = false
        if !fields.size.isEmpty {
            if !fields.quant.isEmpty {
                rows.append(.inline(label: "Size:", primaryValue: fields.size, inlineParts: [(quantLabel, fields.quant)]))
                quantOnSize = true
            } else {
                rows.append(.labelValue(label: "Size:", value: fields.size))
            }
        }
        if !omitLiveStepsRow {
            let display = stepsValue.isEmpty ? fields.steps : stepsValue
            let inline = stepsInlineParts(elapsedSeconds: elapsedSeconds, estimateSeconds: estimateSeconds)
            if !display.isEmpty, !inline.isEmpty {
                rows.append(.inline(label: "Steps:", primaryValue: display, inlineParts: inline))
            } else if !display.isEmpty {
                rows.append(.labelValue(label: "Steps:", value: display))
            }
        }
        if !fields.quant.isEmpty, !quantOnSize {
            rows.append(.labelValue(label: quantLabel, value: fields.quant))
        }
        if !fields.prompt.isEmpty {
            rows.append(.prompt(label: fields.promptLabel, value: fields.prompt))
        }
        if !fields.neg.isEmpty {
            rows.append(.labelValue(label: "Neg:", value: fields.neg))
        }
        return rows
    }

    // MARK: - Helpers

    private static func taskMenuTitle(pipelineID: String) -> String {
        let mode = ImageGenPipelineModeMetadata.mode(pipelineID: pipelineID)
        if mode.promptStatusLabel == "Outfill:" { return "Expand Image" }
        if mode.promptStatusLabel == "Infill:" { return "Infill image" }
        if mode.requiresSourceImage { return "Modify with AI" }
        return "Generate from text"
    }

    private static func jobTitleWithAISuffix(_ title: String) -> String {
        let base = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { return "+AI" }
        if base.hasSuffix("+AI") { return base }
        return "\(base) +AI"
    }

    private static func hasFluxPromptAIJob(_ values: [String: Any]) -> Bool {
        values[JobStepQueue.fluxPromptAIJobKey] is [String: Any]
    }

    private static func fluxPromptAIUserPrompt(_ values: [String: Any]) -> String {
        guard let meta = values[JobStepQueue.fluxPromptAIJobKey] as? [String: Any] else { return "" }
        return meta["user_prompt"] as? String ?? meta["prompt"] as? String ?? ""
    }

    /// Port of ``_series_queued_value``.
    private static func seriesQueuedValue(count: Int) -> String {
        let noun = count == 1 ? "image" : "images"
        return "\(count) \(noun)."
    }

    /// Port of ``format_series_line_value`` / ``_series_refinement_suffix``.
    private static func formatSeriesLine(base: String, values: [String: Any]) -> String {
        var parts: [String] = []
        if values["series_refinement"] as? Bool == true { parts.append("Image Refinement") }
        if values["series_prompt_refinement"] as? Bool == true { parts.append("Text Refinement") }
        guard !parts.isEmpty else { return base }
        return base + "\u{00A0}\u{00A0}\u{00A0}\u{00A0}(" + parts.joined(separator: ", ") + ")"
    }

    private static func resolvedFullPrompt(values: [String: Any]) -> String {
        (values["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizePromptForDisplay(_ text: String) -> String {
        PromptDisplayLayout.clampPromptForDisplay(text, width: 200)
    }

    private static func truncate(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= promptTruncate { return t }
        return String(t.prefix(promptTruncate - 1)) + "…"
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }

    private static func quantizeStatusValue(plugin: ImageGenPluginDescriptor, values: [String: Any]) -> String? {
        guard plugin.reportsQuantization else { return nil }
        let key = plugin.quantizeStatusKey
        let raw = values[key]
        if key == "mlx_tier" {
            let tier = (raw as? String ?? "q4").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch tier {
            case "q4": return "4"
            case "q8": return "8"
            case "bf16": return "16"
            default: return tier.isEmpty ? nil : tier
            }
        }
        return intValue(raw).map { "\($0)" }
    }

    private static func loraLabelForStatus(plugin: ImageGenPluginDescriptor, values: [String: Any]) -> String {
        ImageGenExifCommentFormatting.loraNameForExifFromValues(
            values: values,
            pipelineID: plugin.pipelineID,
            loraHostID: plugin.loraHostID
        ) ?? ""
    }

    private static func stepsDisplay(fieldsSteps: String, step: Int?, stepTotal: Int?) -> String {
        guard let step, let stepTotal, stepTotal > 0 else { return fieldsSteps }
        let s = max(0, min(step, stepTotal))
        return "\(s)/\(stepTotal)"
    }

    private static func stepsInlineParts(
        elapsedSeconds: Double?,
        estimateSeconds: Double?
    ) -> [(String, String)] {
        guard let elapsed = elapsedSeconds else { return [] }
        var parts: [(String, String)] = [("Elapsed:", formatDuration(elapsed))]
        if let est = estimateSeconds, est > 0 {
            parts.append(("Time:", formatDuration(est)))
        }
        return parts
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
