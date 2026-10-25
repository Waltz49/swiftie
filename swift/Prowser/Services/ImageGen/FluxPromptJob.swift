import AppKit
import Foundation
import Observation

/// Port of `imagegen_plugins/flux_prompt_job.py`.
@MainActor
enum FluxPromptJob {
    static func normalizedExistingImagePaths(_ raw: [String]) -> [String] {
        var paths: [String] = []
        for item in raw {
            let normalized = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, FileManager.default.isReadableFile(atPath: normalized) else { continue }
            if !paths.contains(normalized) { paths.append(normalized) }
        }
        return paths
    }

    static func resolveRefineImagePaths(
        function: String,
        sourcePaths: [String],
        activeBrowsePath: String?
    ) -> [String] {
        switch function {
        case "edit":
            if let first = sourcePaths.first {
                return normalizedExistingImagePaths([first])
            }
            return []
        case "expand", "infill":
            if let first = sourcePaths.first {
                return normalizedExistingImagePaths([first])
            }
            return []
        case "create":
            if let active = activeBrowsePath?.trimmingCharacters(in: .whitespacesAndNewlines),
               !active.isEmpty {
                return normalizedExistingImagePaths([active])
            }
            return []
        default:
            if let first = sourcePaths.first {
                return normalizedExistingImagePaths([first])
            }
            return []
        }
    }

    static func preflightAIRefine(
        prompt: String,
        passImage: Bool,
        imagePaths: [String]
    ) -> String? {
        if allowEmptyPromptForAIRefine(prompt: prompt, passImage: passImage, imagePaths: imagePaths) {
            return nil
        }
        if passImage {
            return "Pass image is checked but no image is available.\n\nSelect an image or enter a prompt."
        }
        return nil
    }

    static func allowEmptyPromptForAIRefine(
        prompt: String,
        passImage: Bool,
        imagePaths: [String]
    ) -> Bool {
        if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        guard passImage else { return false }
        return !imagePaths.isEmpty
    }

    static func clearFluxPromptAIJob(_ values: inout [String: Any]) {
        values.removeValue(forKey: JobStepQueue.fluxPromptAIJobKey)
    }

    static func buildFluxPromptAIJobMeta(
        context: ImageGenFluxPromptSubmitContext,
        config: AppConfig
    ) -> [String: Any]? {
        let imagePaths = resolveRefineImagePaths(
            function: context.taskKind,
            sourcePaths: context.sourcePaths,
            activeBrowsePath: context.activeBrowsePath
        )
        if let error = preflightAIRefine(
            prompt: context.promptText,
            passImage: context.passImage,
            imagePaths: context.passImage ? imagePaths : []
        ) {
            _ = error
            return nil
        }
        let userPrompt = context.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = context.passImage ? imagePaths : []
        let system = FluxPromptMessages.resolvedSystemPrompt(
            taskKind: context.taskKind,
            config: config,
            override: context.systemPromptOverride,
            withImage: !paths.isEmpty,
            imageCount: paths.count
        )
        return [
            "system_prompt": system,
            "user_prompt": userPrompt,
            "image_paths": paths,
            "task_kind": context.taskKind,
        ]
    }

    static func fluxPromptAIJobUIActive(context: ImageGenFluxPromptSubmitContext, lmStudioMounted: Bool) -> Bool {
        guard lmStudioMounted, context.sectionExpanded else { return false }
        return true
    }

    static func stripFluxPromptAIJobIfUIInactive(
        context: ImageGenFluxPromptSubmitContext,
        lmStudioMounted: Bool,
        values: inout [String: Any]
    ) {
        if fluxPromptAIJobUIActive(context: context, lmStudioMounted: lmStudioMounted) { return }
        clearFluxPromptAIJob(&values)
    }

    @discardableResult
    static func attachFluxPromptAIJobToValues(
        context: ImageGenFluxPromptSubmitContext,
        config: AppConfig,
        values: inout [String: Any],
        force: Bool = false
    ) -> Bool {
        clearFluxPromptAIJob(&values)
        guard fluxPromptAIJobUIActive(context: context, lmStudioMounted: context.lmStudioMounted) else {
            return false
        }
        if !force, !context.jobCheckbox { return false }
        guard let meta = buildFluxPromptAIJobMeta(context: context, config: config) else { return false }
        values[JobStepQueue.fluxPromptAIJobKey] = meta
        return true
    }

    static func applyFluxPromptJobToPrepareRunValues(
        context: ImageGenFluxPromptSubmitContext,
        config: AppConfig,
        values: inout [String: Any],
        force: Bool = false
    ) -> Bool {
        if !fluxPromptAIJobUIActive(context: context, lmStudioMounted: context.lmStudioMounted) {
            if force { return false }
            clearFluxPromptAIJob(&values)
            return true
        }
        if force {
            return attachFluxPromptAIJobToValues(context: context, config: config, values: &values, force: true)
        }
        attachFluxPromptAIJobToValues(context: context, config: config, values: &values, force: false)
        return true
    }

    static func allowEmptyPromptForFluxAIJob(
        context: ImageGenFluxPromptSubmitContext,
        force: Bool = false
    ) -> Bool {
        guard fluxPromptAIJobUIActive(context: context, lmStudioMounted: context.lmStudioMounted) else {
            return false
        }
        if force || context.jobCheckbox {
            let paths = resolveRefineImagePaths(
                function: context.taskKind,
                sourcePaths: context.sourcePaths,
                activeBrowsePath: context.activeBrowsePath
            )
            return preflightAIRefine(
                prompt: context.promptText,
                passImage: context.passImage,
                imagePaths: context.passImage ? paths : []
            ) == nil
        }
        return false
    }

    static func syncJobCheckboxFromValues(
        values: [String: Any],
        context: ImageGenFluxPromptSubmitContext
    ) {
        guard JobStepQueue.hasFluxPromptAIJob(values) else {
            context.jobCheckbox = false
            return
        }
        if let meta = values[JobStepQueue.fluxPromptAIJobKey] as? [String: Any],
           meta["series_chain_only"] as? Bool == true {
            context.jobCheckbox = false
            return
        }
        context.jobCheckbox = true
    }

    static func resolveRefineImagePathsForJob(
        function: String,
        values: [String: Any],
        config: AppConfig
    ) -> [String] {
        switch function {
        case "edit", "expand", "infill":
            return normalizedExistingImagePaths(ImageGenExifReferences.resolveSourceImagePaths(values))
        case "create":
            if ImageGenPersistence.passImageToAI(config: config) {
                return fluxPromptAIReferenceImagePaths(values)
            }
            return []
        default:
            return normalizedExistingImagePaths(ImageGenExifReferences.resolveSourceImagePaths(values))
        }
    }

    static func fluxPromptAIReferenceImagePaths(_ values: [String: Any]) -> [String] {
        guard let meta = values[JobStepQueue.fluxPromptAIJobKey] as? [String: Any],
              let raw = meta["image_paths"] as? [String] else { return [] }
        return normalizedExistingImagePaths(raw)
    }

    static func fluxPromptAIUserPrompt(_ values: [String: Any]) -> String {
        if let meta = values[JobStepQueue.fluxPromptAIJobKey] as? [String: Any] {
            let user = (meta["user_prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !user.isEmpty { return user }
        }
        return (values["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Port of ``effective_job_prompt_for_tooltip`` (job cards, tooltips, editor restore).
    static func effectiveJobPromptForTooltip(_ values: [String: Any]) -> String {
        FluxPromptJobValues.effectiveJobPromptForTooltip(values)
    }

    /// Keep ``values["prompt"]`` aligned with pre-AI user text for queued job persistence.
    static func preserveOriginalPromptInAIJobValues(_ values: inout [String: Any]) {
        guard JobStepQueue.hasFluxPromptAIJob(values) else { return }
        let original = FluxPromptJobValues.fluxPromptAIUserPrompt(values)
        if !original.isEmpty {
            values["prompt"] = original
        }
    }

    /// Restore dialog prompt + AI system prompt from queued job AI metadata before edit.
    static func restoreFluxPromptAIJobIntoEditor(
        values: inout [String: Any],
        context: ImageGenFluxPromptSubmitContext
    ) {
        guard JobStepQueue.hasFluxPromptAIJob(values),
              let meta = values[JobStepQueue.fluxPromptAIJobKey] as? [String: Any]
        else { return }
        let original = FluxPromptJobValues.fluxPromptAIUserPrompt(values)
        if !original.isEmpty {
            values["prompt"] = original
            context.promptText = original
        }
        let system = (meta["system_prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty {
            context.systemPromptOverride = system
        }
        syncJobCheckboxFromValues(values: values, context: context)
    }

    static func buildFluxPromptAIJobMetaFromJob(
        function: String,
        values: [String: Any],
        config: AppConfig,
        seriesChainOnly: Bool = false
    ) -> [String: Any]? {
        guard !function.isEmpty else { return nil }
        let userPrompt = (values["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let imagePaths = resolveRefineImagePathsForJob(function: function, values: values, config: config)
        let override = ImageGenPersistence.fluxSystemPromptText(config: config)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let system = FluxPromptMessages.resolvedSystemPrompt(
            taskKind: function,
            config: config,
            override: override.isEmpty ? nil : override,
            withImage: !imagePaths.isEmpty,
            imageCount: imagePaths.count
        )
        var meta: [String: Any] = [
            "system_prompt": system,
            "user_prompt": userPrompt,
            "image_paths": imagePaths,
            "task_kind": function,
        ]
        if seriesChainOnly {
            meta["series_chain_only"] = true
        }
        return meta
    }

    static func ensureFluxPromptAIJobForSeries(
        function: String,
        values: inout [String: Any],
        config: AppConfig
    ) -> Bool {
        if let existing = values[JobStepQueue.fluxPromptAIJobKey] as? [String: Any],
           existing["series_chain_only"] as? Bool != true {
            return true
        }
        if let existing = values[JobStepQueue.fluxPromptAIJobKey] as? [String: Any],
           existing["series_chain_only"] as? Bool == true {
            let prompt = (values["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let user = (existing["user_prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !prompt.isEmpty, user.isEmpty {
                var updated = existing
                updated["user_prompt"] = prompt
                values[JobStepQueue.fluxPromptAIJobKey] = updated
            }
            return true
        }
        guard let meta = buildFluxPromptAIJobMetaFromJob(
            function: function,
            values: values,
            config: config,
            seriesChainOnly: true
        ) else { return false }
        values[JobStepQueue.fluxPromptAIJobKey] = meta
        return true
    }

    static func clearSeriesChainFluxPromptAIJob(_ values: inout [String: Any]) {
        guard let meta = values[JobStepQueue.fluxPromptAIJobKey] as? [String: Any],
              meta["series_chain_only"] as? Bool == true else { return }
        clearFluxPromptAIJob(&values)
    }

    static func syncFluxPromptAIUserPromptForNextCopy(
        values: inout [String: Any],
        sourceValues: [String: Any]? = nil
    ) {
        guard var meta = values[JobStepQueue.fluxPromptAIJobKey] as? [String: Any] else { return }
        let src = sourceValues ?? values
        let prompt = (src["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            meta["user_prompt"] = prompt
        }
        if meta["image_paths"] != nil {
            let refreshed = ImageGenExifReferences.resolveSourceImagePaths(values)
                .filter { FileManager.default.isReadableFile(atPath: $0) }
            if !refreshed.isEmpty {
                meta["image_paths"] = refreshed
            }
        }
        values[JobStepQueue.fluxPromptAIJobKey] = meta
    }

    static func multiCopyFixedSeedAllowed(
        values: [String: Any],
        context: ImageGenFluxPromptSubmitContext?
    ) -> Bool {
        if values["series_refinement"] as? Bool == true { return true }
        if values["series_prompt_refinement"] as? Bool == true { return true }
        if JobStepQueue.hasFluxPromptAIJob(values) { return true }
        guard let context else { return false }
        guard fluxPromptAIJobUIActive(context: context, lmStudioMounted: context.lmStudioMounted) else {
            return false
        }
        return context.jobCheckbox
    }

    /// Port of ``prompt_enable_random_seed_for_copies``.
    private enum CopiesRandomSeedDialogChoice: Int {
        case cancel = 0
        case singleWithSeed = 1
        case multiWithRandomSeeds = 2
    }

    private static func promptEnableRandomSeedForCopies(parentWindow: NSWindow?) -> CopiesRandomSeedDialogChoice? {
        let index = StyledMessageDialog.present(
            title: "Random seed required",
            message: "Copies greater than 1 require Random seed to be enabled so each image uses a different seed.",
            style: .warning,
            icon: .warning,
            buttons: [
                StyledMessageDialog.Button("Cancel", role: .dismissive),
                StyledMessageDialog.Button("Single with seed", role: .dismissive),
                StyledMessageDialog.Button("Multi with random seeds"),
            ],
            defaultButtonIndex: CopiesRandomSeedDialogChoice.multiWithRandomSeeds.rawValue,
            escapeButtonIndex: CopiesRandomSeedDialogChoice.cancel.rawValue,
            parentWindow: parentWindow
        )
        guard let index else { return nil }
        return CopiesRandomSeedDialogChoice(rawValue: index)
    }

    /// Port of ``apply_copies_random_seed_choice``.
    private static func applyCopiesRandomSeedChoice(
        values: inout [String: Any],
        choice: CopiesRandomSeedDialogChoice?
    ) -> Bool {
        guard let choice, choice != .cancel else { return false }
        if choice == .singleWithSeed {
            values["copies"] = 1
            return true
        }
        values["random_seed"] = true
        return true
    }

    /// Port of ``apply_copies_random_seed_if_required`` / ``validate_copies_require_random_seed``.
    static func applyCopiesRandomSeedIfRequired(
        values: inout [String: Any],
        copyCount: Int,
        context: ImageGenFluxPromptSubmitContext?
    ) -> Bool {
        if copyCount <= 1 { return true }
        if values["random_seed"] as? Bool ?? false { return true }
        if multiCopyFixedSeedAllowed(values: values, context: context) { return true }
        return applyCopiesRandomSeedChoice(
            values: &values,
            choice: promptEnableRandomSeedForCopies(parentWindow: NSApp.keyWindow)
        )
    }

    static func applyPromptExitsAfterFluxJobResolution(values: inout [String: Any], config: AppConfig) -> Bool {
        if JobStepQueue.hasFluxPromptAIJob(values) { return false }
        let prompt = values["prompt"] as? String ?? ""
        let updated = AIPromptExitService.applyImageAIExit(prompt, config: config)
        guard updated != prompt else { return false }
        values["prompt"] = updated
        return true
    }
}

/// Dialog state for flux AI submit (Python owner + pane visibility).
@MainActor
@Observable
final class ImageGenFluxPromptSubmitContext {
    var sectionExpanded = false
    var passImage = false
    var jobCheckbox = false
    var systemPromptOverride = ""
    var taskKind = "create"
    var sourcePaths: [String] = []
    var activeBrowsePath: String?
    var promptText = ""
    var lmStudioMounted = false
}
