import SwiftUI

/// LM Studio grammar for chat/user prompt edit dialogs (Python ``add_chat_prompt_grammar_button``).
@MainActor
struct ChatPromptGrammarButton: View {
    @Environment(AppState.self) private var appState
    @Binding var text: String

    @State private var isRunning = false
    @State private var promptBefore = ""
    @State private var streamingStarted = false

    private var isAvailable: Bool {
        BundleCapabilities.lmStudioUIEnabled && appState.workers.foregroundModelTasks.isAvailable
    }

    var body: some View {
        Group {
            if isAvailable {
                Button(isRunning ? "Cancel" : "Grammar") {
                    if isRunning {
                        cancelGrammar()
                    } else {
                        startGrammar()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(isRunning
                    ? "Stop the in-progress grammar correction"
                    : "Correct grammar and spelling using LM Studio")
            }
        }
    }

    private func startGrammar() {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            appState.status.show("Enter a prompt before running grammar correction.")
            return
        }
        let bridge = appState.workers.foregroundModelTasks
        guard !bridge.isBusy else {
            appState.status.show("Wait for the current LM Studio task to finish.")
            return
        }

        let prompts = ImageGenGrammarLogic.systemAndUserPrompts(for: prompt)
        promptBefore = text
        isRunning = true
        streamingStarted = false

        bridge.onFluxPromptChunk = { chunk in
            Task { @MainActor in
                guard !chunk.isEmpty else { return }
                if !streamingStarted {
                    streamingStarted = true
                    text = chunk
                } else {
                    text += chunk
                }
            }
        }
        bridge.onFluxPromptReady = { corrected in
            Task { @MainActor in
                text = ChatPromptFormatting.formatAfterGrammar(corrected)
                finishGrammar()
            }
        }
        bridge.onJobFinished = { kind, success, error in
            guard kind == "flux_prompt" else { return }
            Task { @MainActor in
                if !success {
                    if !streamingStarted {
                        text = promptBefore
                    }
                    if !error.isEmpty, error != "Cancelled" {
                        appState.status.show(error)
                    }
                }
                finishGrammar()
            }
        }

        do {
            _ = try bridge.startFluxPrompt(
                prompt: prompts.user,
                systemPrompt: prompts.system,
                imagePaths: []
            )
        } catch {
            text = promptBefore
            appState.status.show(error.localizedDescription)
            finishGrammar()
        }
    }

    private func cancelGrammar() {
        appState.workers.foregroundModelTasks.cancel()
        if !streamingStarted {
            text = promptBefore
        }
        finishGrammar()
    }

    private func finishGrammar() {
        isRunning = false
        streamingStarted = false
        let bridge = appState.workers.foregroundModelTasks
        bridge.onFluxPromptChunk = nil
        bridge.onFluxPromptReady = nil
        bridge.onJobFinished = nil
    }
}
