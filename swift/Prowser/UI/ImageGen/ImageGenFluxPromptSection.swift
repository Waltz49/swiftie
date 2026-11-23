import SwiftUI

@MainActor
struct ImageGenFluxPromptSection: View {
    @Environment(AppState.self) private var appState
    @Binding var values: [String: Any]
    @Bindable var fluxContext: ImageGenFluxPromptSubmitContext
    @Bindable var refineCoordinator: FluxPromptRefineCoordinator
    let function: String
    let sourcePaths: [String]
    let activeBrowsePath: String?
    var onValuesChanged: (() -> Void)?
    var onQueueJobWithAI: (() -> Void)?
    /// When true, Job AI checkbox reflects queued job metadata, not the global preference.
    var editingQueueJob = false

    @State private var systemPromptExpanded = true
    @State private var systemPrompt = ""

    var body: some View {
        if fluxContext.lmStudioMounted {
            ImageGenCollapsibleSection(
                title: "AI Prompt Enhancement",
                isExpanded: $fluxContext.sectionExpanded,
                tooltip: "Refine prompts with a local LM Studio model.",
                headerTrailingLeadingGap: ImageGenCollapsibleSectionMetrics.headerTrailingLeadingGap
            ) {
                fluxPromptJobHeaderToggle
            } content: {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Pass image to Prompt Generator", isOn: $fluxContext.passImage)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .onChange(of: fluxContext.passImage) { _, enabled in
                            guard !editingQueueJob else { return }
                            ImageGenPersistence.setPassImageToAI(enabled, config: appState.config)
                        }

                    HStack(spacing: 16) {
                        Button(refineCoordinator.isRefining ? "Cancel" : "Gen Prompt ⌥↩") {
                            fluxContext.promptText = ImageGenPromptSentenceCase.normalized(
                                values["prompt"] as? String ?? ""
                            )
                            refineCoordinator.requestGenPrompt(
                                appState: appState,
                                context: fluxContext,
                                values: $values,
                                onValuesChanged: onValuesChanged,
                                queueJobWithAI: { onQueueJobWithAI?() }
                            )
                        }
                        .disabled(genPromptDisabled)

                        Button("Undo AI ⇧⌥↩") {
                            refineCoordinator.undoRefine(values: $values, onValuesChanged: onValuesChanged)
                        }
                        .disabled(!refineCoordinator.undoAvailable || refineCoordinator.isRefining)

                        Spacer(minLength: 0)
                    }

                    systemPromptBlock

                    if !refineCoordinator.refineError.isEmpty {
                        Text(refineCoordinator.refineError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(.top, 16)
            .onAppear {
                loadSettings()
                syncContextFromValues()
            }
            .onChange(of: fluxContext.sectionExpanded) { _, _ in
                persistSectionState()
            }
            .onChange(of: systemPromptExpanded) { _, _ in
                persistSectionState()
            }
            .onChange(of: function) { _, newFunction in
                fluxContext.taskKind = newFunction
            }
            .onChange(of: sourcePaths) { _, paths in
                fluxContext.sourcePaths = paths
            }
            .onChange(of: activeBrowsePath) { _, path in
                fluxContext.activeBrowsePath = path
            }
            .onDisappear {
                refineCoordinator.teardown(appState: appState)
            }
        }
    }

    private var fluxPromptJobHeaderToggle: some View {
        HStack(spacing: 8) {
            SettingsPreferenceSwitch(isOn: $fluxContext.jobCheckbox)
            SettingsPreferenceSwitchTitle(
                title: "Job: Include AI Prompt Refinement in jobs",
                font: .caption,
                color: .primary,
                isOn: $fluxContext.jobCheckbox
            )
        }
        .help(
            "When enabled, Generate runs AI prompt refinement as the first stage "
                + "of the image job (queued or immediate)."
        )
        .onChange(of: fluxContext.jobCheckbox) { _, enabled in
            values["flux_prompt_job_with_generate"] = enabled
            if !editingQueueJob {
                ImageGenPersistence.setFluxPromptJobWithGenerate(enabled, config: appState.config)
            }
            onValuesChanged?()
        }
    }

    private var genPromptDisabled: Bool {
        if refineCoordinator.isRefining { return false }
        let prompt = (values["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { return false }
        let paths = FluxPromptJob.resolveRefineImagePaths(
            function: function,
            sourcePaths: sourcePaths,
            activeBrowsePath: activeBrowsePath
        )
        return paths.isEmpty
    }

    private var systemPromptBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Button {
                    systemPromptExpanded.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text(systemPromptExpanded ? "▼" : "▶")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text("System Prompt")
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                }
                .buttonStyle(.plain)
                .help("Click to expand or collapse system prompt")

                Spacer(minLength: 0)

                ImageGenPromptActionButtons(
                    text: systemPrompt,
                    defaultText: ImageGenPromptDefaults.systemPromptResetText,
                    includeFavorite: false,
                    onTextChanged: { newText in
                        systemPrompt = newText
                        fluxContext.systemPromptOverride = newText
                        persistSectionState()
                        onValuesChanged?()
                    }
                )
            }

            if systemPromptExpanded {
                ImageGenPromptPlainTextEdit(
                    text: $systemPrompt,
                    minLines: ImageGenPromptLayout.systemPromptMinLines,
                    maxLines: ImageGenPromptLayout.systemPromptMaxLines,
                    sentenceCasePerLine: true
                )
                .onChange(of: systemPrompt) { _, text in
                    fluxContext.systemPromptOverride = text
                    persistSectionState()
                    onValuesChanged?()
                }
            }
        }
    }

    private func loadSettings() {
        FluxPromptJob.loadFluxPromptEditorState(
            values: values,
            context: fluxContext,
            systemPrompt: &systemPrompt,
            systemPromptEditorExpanded: &systemPromptExpanded,
            config: appState.config,
            editingQueueJob: editingQueueJob
        )
        fluxContext.taskKind = function
        fluxContext.sourcePaths = sourcePaths
        fluxContext.activeBrowsePath = activeBrowsePath
        values["flux_prompt_job_with_generate"] = fluxContext.jobCheckbox
    }

    private func syncContextFromValues() {
        let override = fluxContext.systemPromptOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty {
            systemPrompt = override
        }
    }

    private func persistSectionState() {
        guard !editingQueueJob else { return }
        ImageGenPersistence.saveFluxSystemPromptSettings(
            text: systemPrompt,
            sectionVisible: fluxContext.sectionExpanded,
            editorExpanded: systemPromptExpanded,
            config: appState.config
        )
    }
}
