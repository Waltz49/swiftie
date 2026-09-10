import SwiftUI

@MainActor
struct ImageGenFluxPromptSection: View {
    @Environment(AppState.self) private var appState
    @Binding var values: [String: Any]
    let function: String
    let sourcePaths: [String]
    var onValuesChanged: (() -> Void)?

    @State private var isExpanded = false
    @State private var systemPrompt = ""
    @State private var passImage = false
    @State private var jobWithGenerate = false
    @State private var isRefining = false
    @State private var undoPrompt: String?
    @State private var refineError = ""

    var body: some View {
        if appState.workers.foregroundModelTasks.isAvailable {
            ImageGenCollapsibleSection(
                title: "AI Prompt Enhancement",
                isExpanded: $isExpanded,
                tooltip: "Refine prompts with a local LM Studio model."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $systemPrompt)
                        .font(.body.monospaced())
                        .frame(minHeight: 72, maxHeight: 120)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        .onChange(of: systemPrompt) { _, text in
                            ImageGenPersistence.saveFluxSystemPrompt(
                                text: text,
                                expanded: isExpanded,
                                config: appState.config
                            )
                            onValuesChanged?()
                        }

                    HStack(spacing: 8) {
                        Button(isRefining ? "Cancel" : "Gen Prompt") {
                            if isRefining {
                                appState.workers.foregroundModelTasks.cancel()
                            } else {
                                startRefine()
                            }
                        }
                        .keyboardShortcut(.return, modifiers: [.option])
                        .disabled(!isRefining && promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && sourcePaths.isEmpty)

                        Button("Undo AI") {
                            undoRefine()
                        }
                        .keyboardShortcut(.return, modifiers: [.option, .shift])
                        .disabled(undoPrompt == nil)

                        Toggle("Pass image", isOn: $passImage)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                            .onChange(of: passImage) { _, enabled in
                                ImageGenPersistence.setPassImageToAI(enabled, config: appState.config)
                            }

                        Toggle("Job AI", isOn: $jobWithGenerate)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                            .onChange(of: jobWithGenerate) { _, enabled in
                                ImageGenPersistence.setFluxPromptJobWithGenerate(enabled, config: appState.config)
                                values["flux_prompt_job_with_generate"] = enabled
                                onValuesChanged?()
                            }
                    }

                    if !refineError.isEmpty {
                        Text(refineError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .onAppear { loadSettings() }
            .onChange(of: isExpanded) { _, expanded in
                ImageGenPersistence.saveFluxSystemPrompt(
                    text: systemPrompt,
                    expanded: expanded,
                    config: appState.config
                )
            }
            .onDisappear {
                appState.workers.foregroundModelTasks.onFluxPromptChunk = nil
                appState.workers.foregroundModelTasks.onFluxPromptReady = nil
                appState.workers.foregroundModelTasks.onJobFinished = nil
            }
        }
    }

    private var promptText: String {
        values["prompt"] as? String ?? ""
    }

    private func loadSettings() {
        systemPrompt = ImageGenPersistence.fluxSystemPromptText(config: appState.config)
        isExpanded = ImageGenPersistence.fluxSystemPromptExpanded(config: appState.config)
        passImage = ImageGenPersistence.passImageToAI(config: appState.config)
        jobWithGenerate = ImageGenPersistence.fluxPromptJobWithGenerate(config: appState.config)
        values["flux_prompt_job_with_generate"] = jobWithGenerate
    }

    private func startRefine() {
        refineError = ""
        undoPrompt = promptText
        isRefining = true
        let bridge = appState.workers.foregroundModelTasks
        bridge.onFluxPromptChunk = { chunk in
            let current = values["prompt"] as? String ?? ""
            values["prompt"] = current + chunk
            onValuesChanged?()
        }
        bridge.onFluxPromptReady = { refined in
            values["prompt"] = refined
            isRefining = false
            onValuesChanged?()
        }
        bridge.onJobFinished = { kind, success, error in
            guard kind == "flux_prompt" else { return }
            isRefining = false
            if !success, !error.isEmpty, error != "Cancelled" {
                refineError = error
            }
        }
        let imagePaths = passImage ? sourcePaths : []
        do {
            _ = try bridge.startFluxPrompt(prompt: promptText, imagePaths: imagePaths)
        } catch {
            isRefining = false
            refineError = error.localizedDescription
        }
    }

    private func undoRefine() {
        guard let undoPrompt else { return }
        values["prompt"] = undoPrompt
        self.undoPrompt = nil
        onValuesChanged?()
    }
}
