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

    @State private var systemPromptExpanded = true
    @State private var systemPrompt = ""

    var body: some View {
        if fluxContext.lmStudioMounted {
            ImageGenCollapsibleSection(
                title: "AI Prompt Enhancement",
                isExpanded: $fluxContext.sectionExpanded,
                tooltip: "Refine prompts with a local LM Studio model."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Pass image to Prompt Generator", isOn: $fluxContext.passImage)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .onChange(of: fluxContext.passImage) { _, enabled in
                            ImageGenPersistence.setPassImageToAI(enabled, config: appState.config)
                        }

                    HStack(spacing: 16) {
                        Button(refineCoordinator.isRefining ? "Cancel" : "Gen Prompt ⌥↩") {
                            fluxContext.promptText = values["prompt"] as? String ?? ""
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

                    Toggle("Job: Include AI Prompt Refinement in jobs", isOn: $fluxContext.jobCheckbox)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .padding(.leading, 18)
                        .onChange(of: fluxContext.jobCheckbox) { _, enabled in
                            ImageGenPersistence.setFluxPromptJobWithGenerate(enabled, config: appState.config)
                            values["flux_prompt_job_with_generate"] = enabled
                            onValuesChanged?()
                        }

                    if !refineCoordinator.refineError.isEmpty {
                        Text(refineCoordinator.refineError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .onAppear {
                loadSettings()
                syncContextFromValues()
            }
            .onChange(of: fluxContext.sectionExpanded) { _, _ in
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
                TextEditor(text: $systemPrompt)
                    .frame(minHeight: 72, maxHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    .imageGenPromptSentenceCaseOnBlur($systemPrompt, perLine: true)
                    .onChange(of: systemPrompt) { _, text in
                        fluxContext.systemPromptOverride = text
                        persistSectionState()
                        onValuesChanged?()
                    }
            }
        }
    }

    private func loadSettings() {
        systemPrompt = ImageGenPersistence.fluxSystemPromptText(config: appState.config)
        fluxContext.systemPromptOverride = systemPrompt
        fluxContext.sectionExpanded = ImageGenPersistence.fluxSystemPromptExpanded(config: appState.config)
        fluxContext.passImage = ImageGenPersistence.passImageToAI(config: appState.config)
        fluxContext.jobCheckbox = ImageGenPersistence.fluxPromptJobWithGenerate(config: appState.config)
        fluxContext.taskKind = function
        fluxContext.sourcePaths = sourcePaths
        fluxContext.activeBrowsePath = activeBrowsePath
        values["flux_prompt_job_with_generate"] = fluxContext.jobCheckbox
    }

    private func syncContextFromValues() {
        FluxPromptJob.syncJobCheckboxFromValues(values: values, context: fluxContext)
        let override = fluxContext.systemPromptOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty {
            systemPrompt = override
        }
    }

    private func persistSectionState() {
        ImageGenPersistence.saveFluxSystemPrompt(
            text: systemPrompt,
            expanded: fluxContext.sectionExpanded,
            config: appState.config
        )
    }
}
