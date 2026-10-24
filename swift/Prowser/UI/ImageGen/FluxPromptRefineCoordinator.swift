import AppKit
import Foundation
import SwiftUI

@MainActor
@Observable
final class FluxPromptRefineCoordinator {
    var isRefining = false
    var undoAvailable = false
    var refineError = ""
    let promptStreamSession = ImageGenPromptStreamSession()

    private var promptBeforeAI = ""
    private var streamingStarted = false
    private var userCancelled = false
    private var dotPhase = 0
    private var dotTimer: Timer?
    private var dotAnimationTick: (() -> Void)?

    func genShortcutActive(context: ImageGenFluxPromptSubmitContext) -> Bool {
        context.lmStudioMounted && context.sectionExpanded
    }

    func undoShortcutActive(context: ImageGenFluxPromptSubmitContext) -> Bool {
        guard context.lmStudioMounted, context.sectionExpanded else { return false }
        return undoAvailable && !isRefining
    }

    func cancelRefine(appState: AppState) {
        userCancelled = true
        appState.imageGen.cancelFluxPromptRefine()
    }

    func undoRefine(
        values: Binding<[String: Any]>,
        onValuesChanged: (() -> Void)?
    ) {
        guard !promptBeforeAI.isEmpty else { return }
        values.wrappedValue["prompt"] = promptBeforeAI
        promptBeforeAI = ""
        undoAvailable = false
        onValuesChanged?()
    }

    /// After Replace/Update (or loading a queue job), prior refine undo must not revert past the job baseline.
    func clearRefineUndoState() {
        promptBeforeAI = ""
        undoAvailable = false
    }

    func startRefine(
        appState: AppState,
        context: ImageGenFluxPromptSubmitContext,
        values: Binding<[String: Any]>,
        useForeground: Bool,
        onValuesChanged: (() -> Void)?
    ) {
        refineError = ""
        let paths = context.passImage
            ? FluxPromptJob.resolveRefineImagePaths(
                function: context.taskKind,
                sourcePaths: context.sourcePaths,
                activeBrowsePath: context.activeBrowsePath
            )
            : []
        if let preflight = FluxPromptJob.preflightAIRefine(
            prompt: context.promptText,
            passImage: context.passImage,
            imagePaths: paths
        ) {
            showAIError(preflight)
            return
        }

        if useForeground && appState.workers.foregroundModelTasks.isBusy {
            showAIError("A foreground AI text task is already running.")
            return
        }

        let bridge = useForeground
            ? appState.workers.foregroundModelTasks
            : appState.workers.fluxPromptTasks
        if appState.workers.foregroundModelTasks.isBusy && !useForeground {
            showAIError(
                "Grammar correction is already running.\n\nWait for it to finish or cancel it first."
            )
            return
        }
        if bridge.isBusy {
            showAIError("Could not start AI prompt refinement (another task may be running).")
            return
        }

        promptBeforeAI = context.promptText
        undoAvailable = false
        userCancelled = false
        isRefining = true
        streamingStarted = false
        promptStreamSession.begin()
        startDotAnimation(values: values, onValuesChanged: onValuesChanged)

        let override = context.systemPromptOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemOverride = override.isEmpty ? nil : override

        bridge.onFluxPromptChunk = { [weak self] chunk in
            Task { @MainActor in
                guard let self, !chunk.isEmpty else { return }
                if !self.streamingStarted {
                    self.streamingStarted = true
                    self.stopDotAnimation()
                    values.wrappedValue["prompt"] = chunk
                } else {
                    let current = values.wrappedValue["prompt"] as? String ?? ""
                    values.wrappedValue["prompt"] = current + chunk
                }
                onValuesChanged?()
            }
        }
        bridge.onFluxPromptReady = { refined in
            Task { @MainActor in
                values.wrappedValue["prompt"] = refined
                onValuesChanged?()
            }
        }
        bridge.onJobFinished = { [weak self] kind, success, error in
            guard kind == "flux_prompt" else { return }
            Task { @MainActor in
                guard let self else { return }
                self.stopDotAnimation()
                if self.userCancelled {
                    values.wrappedValue["prompt"] = self.promptBeforeAI
                    self.promptBeforeAI = ""
                    self.undoAvailable = false
                    self.finishRefine(success: false, onValuesChanged: onValuesChanged)
                    return
                }
                if !success {
                    values.wrappedValue["prompt"] = self.promptBeforeAI
                    self.promptBeforeAI = ""
                    self.undoAvailable = false
                    if !error.isEmpty, error != "Cancelled" {
                        self.refineError = error
                        self.showAIError(error)
                    }
                    self.finishRefine(success: false, onValuesChanged: onValuesChanged)
                    return
                }
                self.undoAvailable = !self.promptBeforeAI.isEmpty
                self.finishRefine(success: true, onValuesChanged: onValuesChanged)
            }
        }

        do {
            _ = try bridge.startFluxPrompt(
                prompt: promptBeforeAI,
                systemPrompt: systemOverride,
                imagePaths: paths,
                taskKind: context.taskKind
            )
        } catch {
            stopDotAnimation()
            values.wrappedValue["prompt"] = promptBeforeAI
            promptBeforeAI = ""
            undoAvailable = false
            refineError = error.localizedDescription
            finishRefine(success: false, onValuesChanged: onValuesChanged)
        }
    }

    func requestGenPrompt(
        appState: AppState,
        context: ImageGenFluxPromptSubmitContext,
        values: Binding<[String: Any]>,
        onValuesChanged: (() -> Void)?,
        queueJobWithAI: @escaping () -> Void
    ) {
        if isRefining {
            cancelRefine(appState: appState)
            return
        }
        context.promptText = values.wrappedValue["prompt"] as? String ?? ""
        if appState.imageGen.hasPendingWork() {
            if appState.imageGen.fluxPromptRefineShouldBypassPendingWorkDialog() {
                startRefine(
                    appState: appState,
                    context: context,
                    values: values,
                    useForeground: true,
                    onValuesChanged: onValuesChanged
                )
                return
            }
            let choice = StyledMessageDialog.present(
                title: "AI Prompt Error",
                message: "Wait for the job queue to finish or cancel queued jobs before refining a prompt with AI.",
                style: .warning,
                buttons: [
                    StyledMessageDialog.Button("Cancel", role: .dismissive),
                    StyledMessageDialog.Button("Run Now"),
                    StyledMessageDialog.Button("Queue Job"),
                ],
                defaultButtonIndex: 1,
                escapeButtonIndex: 0
            )
            switch choice {
            case 1:
                startRefine(
                    appState: appState,
                    context: context,
                    values: values,
                    useForeground: true,
                    onValuesChanged: onValuesChanged
                )
            case 2:
                queueJobWithAI()
            default:
                break
            }
            return
        }
        startRefine(
            appState: appState,
            context: context,
            values: values,
            useForeground: false,
            onValuesChanged: onValuesChanged
        )
    }

    func teardown(appState: AppState) {
        stopDotAnimation()
        appState.workers.foregroundModelTasks.onFluxPromptChunk = nil
        appState.workers.foregroundModelTasks.onFluxPromptReady = nil
        appState.workers.foregroundModelTasks.onJobFinished = nil
        appState.workers.fluxPromptTasks.onFluxPromptChunk = nil
        appState.workers.fluxPromptTasks.onFluxPromptReady = nil
        appState.workers.fluxPromptTasks.onJobFinished = nil
    }

    private func finishRefine(success: Bool, onValuesChanged: (() -> Void)?) {
        _ = success
        isRefining = false
        streamingStarted = false
        userCancelled = false
        promptStreamSession.end()
        onValuesChanged?()
    }

    private func showAIError(_ message: String) {
        StyledMessageDialog.present(
            title: "AI Prompt Error",
            message: message,
            style: .warning,
            buttons: [StyledMessageDialog.Button("Cancel", role: .dismissive)],
            escapeButtonIndex: 0,
            parentWindow: NSApp.keyWindow
        )
    }

    private func startDotAnimation(
        values: Binding<[String: Any]>,
        onValuesChanged: (() -> Void)?
    ) {
        stopDotAnimation()
        dotPhase = 0
        dotAnimationTick = { [weak self] in
            guard let self, self.isRefining, !self.streamingStarted else { return }
            self.dotPhase = (self.dotPhase + 1) % 4
            values.wrappedValue["prompt"] = String(repeating: ".", count: self.dotPhase + 1)
            onValuesChanged?()
        }
        dotTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dotAnimationTick?()
            }
        }
        if let dotTimer {
            RunLoop.main.add(dotTimer, forMode: .common)
        }
    }

    private func stopDotAnimation() {
        dotTimer?.invalidate()
        dotTimer = nil
        dotAnimationTick = nil
    }
}
