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
        cancel()
        activeTask = Task {
            do {
                let final = try await caption.streamChatCompletion(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    imagePaths: imagePaths,
                    config: config,
                    onChunk: onChunk
                )
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
