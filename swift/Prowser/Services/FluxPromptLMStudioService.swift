import Foundation

@MainActor
final class FluxPromptLMStudioService {
    private let caption = LmStudioCaptionService.shared
    private var activeTask: Task<Void, Never>?

    func probe(config: AppConfig) async -> Bool {
        await caption.probeServicesIfNeeded(config: config)
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
    }

    func streamRefinement(
        systemPrompt: String,
        userPrompt: String,
        imagePaths: [String],
        config: AppConfig,
        onChunk: @escaping @MainActor (String) -> Void,
        onFinished: @escaping @MainActor (Result<String, Error>) -> Void
    ) {
        streamRefinement(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            imagePaths: imagePaths,
            config: config,
            rejectedPhraseRetry: false,
            onRejectionRestarted: nil,
            onChunk: onChunk,
            onFinished: onFinished
        )
    }

    /// Batch job AI: retry LM Studio stream up to 5 times when a forbidden phrase appears (port of chat rejection retry).
    func streamJobRefinement(
        systemPrompt: String,
        userPrompt: String,
        imagePaths: [String],
        config: AppConfig,
        onRejectionRestarted: @escaping @MainActor () -> Void,
        onChunk: @escaping @MainActor (String) -> Void,
        onFinished: @escaping @MainActor (Result<String, Error>) -> Void
    ) {
        streamRefinement(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            imagePaths: imagePaths,
            config: config,
            rejectedPhraseRetry: true,
            onRejectionRestarted: onRejectionRestarted,
            onChunk: onChunk,
            onFinished: onFinished
        )
    }

    private func streamRefinement(
        systemPrompt: String,
        userPrompt: String,
        imagePaths: [String],
        config: AppConfig,
        rejectedPhraseRetry: Bool,
        onRejectionRestarted: (@MainActor () -> Void)?,
        onChunk: @escaping @MainActor (String) -> Void,
        onFinished: @escaping @MainActor (Result<String, Error>) -> Void
    ) {
        cancel()
        activeTask = Task {
            do {
                let final: String
                if rejectedPhraseRetry {
                    let outcome = try await ChatRejectedPhraseStreamRetry.runWithRejectionRetry(
                        config: config,
                        logLabel: "job-ai",
                        onChunk: onChunk,
                        onRestarted: onRejectionRestarted,
                        streamOnce: { [self] emit in
                            _ = try await caption.streamChatCompletion(
                                systemPrompt: systemPrompt,
                                userPrompt: userPrompt,
                                imagePaths: imagePaths,
                                config: config,
                                onChunk: emit
                            )
                        }
                    )
                    let text = LmStudioCaptionService.finalizeChatResponse(outcome.accumulated)
                    guard !text.isEmpty else {
                        throw LmStudioCaptionService.CaptionError.runtime(
                            "The model returned an empty response.\n\n"
                                + "Try a different prompt or check the loaded model."
                        )
                    }
                    final = text
                } else {
                    final = try await caption.streamChatCompletion(
                        systemPrompt: systemPrompt,
                        userPrompt: userPrompt,
                        imagePaths: imagePaths,
                        config: config,
                        onChunk: onChunk
                    )
                }
                guard !Task.isCancelled else {
                    onFinished(.failure(LmStudioCaptionService.CaptionError.cancelled))
                    activeTask = nil
                    return
                }
                onFinished(.success(final))
            } catch {
                if error is CancellationError
                    || (error as? LmStudioCaptionService.CaptionError) == .cancelled {
                    onFinished(.failure(LmStudioCaptionService.CaptionError.cancelled))
                } else {
                    onFinished(.failure(error))
                }
            }
            activeTask = nil
        }
    }
}
