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
        let userPrompt = ImageGenPromptSentenceCase.normalized(context.promptText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
            fluxPromptAIJobMetaPassImageKey: context.passImage,
        ]
    }

    /// Meta keys carried on each job / step for Job AI (snapshot on submit; edit via queue dialog).
    static let fluxPromptAIJobMetaPassImageKey = "pass_image"

    private static func systemPromptTextFromJobMeta(_ meta: [String: Any], config: AppConfig) -> String {
        let system = (meta["system_prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty { return system }
        return ImageGenPersistence.fluxSystemPromptText(config: config)
    }

    /// Whether Job AI controls participate in submit (Generate / Replace / Update).
    ///
    /// The Job AI toggle lives in the section header and stays visible when collapsed; honoring
    /// ``jobCheckbox`` matches that UX (Python hides the toggle inside collapsed content).
    static func fluxPromptAIJobUIActive(context: ImageGenFluxPromptSubmitContext) -> Bool {
        guard context.lmStudioMounted else { return false }
        return context.sectionExpanded || context.jobCheckbox
    }

    @discardableResult
    static func attachFluxPromptAIJobToValues(
        context: ImageGenFluxPromptSubmitContext,
        config: AppConfig,
        values: inout [String: Any],
        force: Bool = false
    ) -> Bool {
        clearFluxPromptAIJob(&values)
        guard fluxPromptAIJobUIActive(context: context) else {
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
        if !fluxPromptAIJobUIActive(context: context) {
            if force { return false }
            clearFluxPromptAIJob(&values)
            return true
        }
        if force {
            return attachFluxPromptAIJobToValues(context: context, config: config, values: &values, force: true)
        }
        let attached = attachFluxPromptAIJobToValues(
            context: context,
            config: config,
            values: &values,
            force: false
        )
        if context.jobCheckbox, !attached {
            return false
        }
        return true
    }

    static func allowEmptyPromptForFluxAIJob(
        context: ImageGenFluxPromptSubmitContext,
        force: Bool = false
    ) -> Bool {
        guard fluxPromptAIJobUIActive(context: context) else {
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
        let tempRoot = config.temporaryFilesDirectory.path
        if let canonical = values["_canonical_source_image_paths"] as? [String] {
            let paths = canonical
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .filter { !ImageGenInfillPathSemantics.isWorkingTempPath($0, tempRoot: tempRoot) }
            let normalized = normalizedExistingImagePaths(paths)
            if !normalized.isEmpty { return normalized }
        }
        switch function {
        case "edit", "expand":
            return normalizedExistingImagePaths(ImageGenExifReferences.resolveSourceImagePaths(values))
        case "infill":
            var paths = ImageGenExifReferences.resolveSourceImagePaths(values)
            if paths.isEmpty {
                for key in ["pixelmator_base_path", "pixelmator_doc_path"] {
                    let raw = (values[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !raw.isEmpty { paths.append(raw) }
                }
            }
            return normalizedExistingImagePaths(paths)
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

    /// Restore dialog prompt + AI fields from queued job metadata (``syncJobCheckboxFromValues`` is separate).
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
        if let pass = passImageStoredInJobMeta(meta) {
            context.passImage = pass
        }
    }

    private static func passImageStoredInJobMeta(_ meta: [String: Any]) -> Bool? {
        if let pass = meta[fluxPromptAIJobMetaPassImageKey] as? Bool { return pass }
        guard meta["image_paths"] != nil else { return nil }
        return !(meta["image_paths"] as? [String] ?? []).isEmpty
    }

    /// Load AI Prompt Enhancement controls from queued job metadata or global preferences.
    static func loadFluxPromptEditorState(
        values: [String: Any],
        context: ImageGenFluxPromptSubmitContext,
        systemPrompt: inout String,
        systemPromptEditorExpanded: inout Bool,
        config: AppConfig,
        editingQueueJob: Bool
    ) {
        if editingQueueJob {
            syncJobCheckboxFromValues(values: values, context: context)
            if JobStepQueue.hasFluxPromptAIJob(values),
               let meta = values[JobStepQueue.fluxPromptAIJobKey] as? [String: Any] {
                systemPrompt = systemPromptTextFromJobMeta(meta, config: config)
                context.systemPromptOverride = systemPrompt
                context.passImage = passImageStoredInJobMeta(meta)
                    ?? ImageGenPersistence.passImageToAI(config: config)
            } else {
                systemPrompt = ImageGenPersistence.fluxSystemPromptText(config: config)
                context.systemPromptOverride = systemPrompt
                context.passImage = ImageGenPersistence.passImageToAI(config: config)
            }
            context.sectionExpanded = ImageGenPersistence.fluxPromptSectionExpandedOnDialogOpen(
                jobAIInBatch: context.jobCheckbox,
                config: config
            )
            systemPromptEditorExpanded = ImageGenPersistence.fluxSystemPromptEditorExpanded(config: config)
            return
        }
        systemPrompt = ImageGenPersistence.fluxSystemPromptText(config: config)
        context.systemPromptOverride = systemPrompt
        systemPromptEditorExpanded = ImageGenPersistence.fluxSystemPromptEditorExpanded(config: config)
        context.passImage = ImageGenPersistence.passImageToAI(config: config)
        context.jobCheckbox = ImageGenPersistence.fluxPromptJobWithGenerate(config: config)
        context.sectionExpanded = ImageGenPersistence.fluxPromptSectionExpandedOnDialogOpen(
            jobAIInBatch: context.jobCheckbox,
            config: config
        )
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
        let passImage = imagePaths.isEmpty
            ? ImageGenPersistence.passImageToAI(config: config)
            : true
        var meta: [String: Any] = [
            "system_prompt": system,
            "user_prompt": userPrompt,
            "image_paths": imagePaths,
            "task_kind": function,
            fluxPromptAIJobMetaPassImageKey: passImage,
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

    static func multiCopyFixedSeedAllowed(
        values: [String: Any],
        context: ImageGenFluxPromptSubmitContext?
    ) -> Bool {
        if values["series_refinement"] as? Bool == true { return true }
        if values["series_prompt_refinement"] as? Bool == true { return true }
        if JobStepQueue.hasFluxPromptAIJob(values) { return true }
        guard let context else { return false }
        guard context.lmStudioMounted else {
            return false
        }
        return context.jobCheckbox
    }

    private static let copiesRandomSeedMessage =
        "Copies greater than 1 require Random seed to be enabled so each image uses a different seed."

    /// Port of ``prompt_enable_random_seed_for_copies``.
    private enum CopiesRandomSeedDialogChoice: Int {
        case cancel = 0
        case singleWithSeed = 1
        case multiWithRandomSeeds = 2
    }

    private static func promptEnableRandomSeedForCopies(parentWindow: NSWindow?) -> CopiesRandomSeedDialogChoice? {
        let index = StyledMessageDialog.present(
            title: "Random seed required",
            message: copiesRandomSeedMessage,
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
        guard let index, let choice = CopiesRandomSeedDialogChoice(rawValue: index) else { return nil }
        return choice
    }

    /// Port of ``apply_copies_random_seed_choice``.
    private static func applyCopiesRandomSeedChoice(
        values: inout [String: Any],
        choice: CopiesRandomSeedDialogChoice?
    ) -> Bool {
        switch choice {
        case nil, .cancel:
            return false
        case .singleWithSeed:
            values["copies"] = 1
            return true
        case .multiWithRandomSeeds:
            values["random_seed"] = true
            return true
        }
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

    /// Dialog submit must not call this: exits run per copy in ``buildPayload`` so ``[L]`` can re-roll.
    static func applyPromptExitsAfterFluxJobResolution(values: inout [String: Any], config: AppConfig) -> Bool {
        if JobStepQueue.hasFluxPromptAIJob(values) { return false }
        let prompt = values["prompt"] as? String ?? ""
        let filtered = ImageGenMfluxPayloadBuilder.applyImageAIExitForRun(prompt: prompt, config: config)
        guard filtered != prompt else { return false }
        values["prompt"] = ImageGenPromptSentenceCase.afterPromptExit(filtered)
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
