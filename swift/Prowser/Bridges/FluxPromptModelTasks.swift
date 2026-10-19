import Foundation

/// LM Studio flux-prompt tasks (port of `ModelTasksController.start_flux_prompt_job`).
@MainActor
final class FluxPromptModelTasks {
    private let service = FluxPromptLMStudioService()
    private weak var config: AppConfig?

    private(set) var isReady = false
    private(set) var isBusy = false
    private(set) var activeJobID = ""
    private(set) var activeKind = ""
    private(set) var lastError = ""

    var isAvailable: Bool { isReady }

    var onFluxPromptChunk: ((String) -> Void)?
    var onFluxPromptReady: ((String) -> Void)?
    var onJobFinished: ((String, Bool, String) -> Void)?

    func bind(config: AppConfig) {
        self.config = config
    }

    func markAvailable(_ available: Bool) {
        isReady = available
    }

    func probe(config: AppConfig) async {
        bind(config: config)
        let ok = await service.probe(config: config)
        isReady = ok
    }

    func cancel() {
        guard isBusy else { return }
        service.cancel()
        let kind = activeKind
        let jobID = activeJobID
        finishJob(kind: kind, jobID: jobID, success: false, error: "Cancelled")
    }

    func shutdown() {
        cancel()
        isReady = false
    }

    @discardableResult
    func startFluxPrompt(
        prompt: String,
        systemPrompt: String? = nil,
        imagePaths: [String] = [],
        taskKind: String = "create"
    ) throws -> String {
        guard let config else { throw BridgeError.pythonUnavailable }
        guard isReady else { throw BridgeError.pythonUnavailable }
        guard !isBusy else { throw BridgeError.busy }

        let paths = FluxPromptJob.normalizedExistingImagePaths(imagePaths)
        let withImage = !paths.isEmpty
        let userText = FluxPromptMessages.userMessage(userPrompt: prompt, withImage: withImage)
        let system = FluxPromptMessages.resolvedSystemPrompt(
            taskKind: taskKind,
            config: config,
            override: systemPrompt,
            withImage: withImage,
            imageCount: paths.count
        )

        let jobID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        activeJobID = jobID
        activeKind = "flux_prompt"
        isBusy = true
        lastError = ""

        service.streamRefinement(
            systemPrompt: system,
            userPrompt: userText,
            imagePaths: paths,
            config: config,
            onChunk: { [weak self] chunk in
                self?.onFluxPromptChunk?(chunk)
            },
            onFinished: { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let text):
                    onFluxPromptReady?(text)
                    finishJob(kind: "flux_prompt", jobID: jobID, success: true, error: "")
                case .failure(let error):
                    let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                    if message == "Cancelled" {
                        finishJob(kind: "flux_prompt", jobID: jobID, success: false, error: "Cancelled")
                    } else {
                        lastError = message
                        finishJob(kind: "flux_prompt", jobID: jobID, success: false, error: message)
                    }
                }
            }
        )
        return jobID
    }

    /// Job AI stage: explicit system/user from ``flux_prompt_ai_job`` metadata.
    @discardableResult
    func startFluxPromptJob(
        systemPrompt: String,
        userPrompt: String,
        imagePaths: [String]
    ) throws -> String {
        guard let config else { throw BridgeError.pythonUnavailable }
        guard isReady else { throw BridgeError.pythonUnavailable }
        guard !isBusy else { throw BridgeError.busy }

        let paths = FluxPromptJob.normalizedExistingImagePaths(imagePaths)
        let withImage = !paths.isEmpty
        let userText = FluxPromptMessages.userMessage(userPrompt: userPrompt, withImage: withImage)
        var system = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if system.isEmpty {
            system = FluxPromptMessages.resolvedSystemPrompt(
                taskKind: "create",
                config: config,
                override: nil,
                withImage: withImage,
                imageCount: paths.count
            )
        }

        let jobID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        activeJobID = jobID
        activeKind = "flux_prompt"
        isBusy = true
        lastError = ""

        service.streamRefinement(
            systemPrompt: system,
            userPrompt: userText,
            imagePaths: paths,
            config: config,
            onChunk: { [weak self] chunk in
                self?.onFluxPromptChunk?(chunk)
            },
            onFinished: { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let text):
                    onFluxPromptReady?(text)
                    finishJob(kind: "flux_prompt", jobID: jobID, success: true, error: "")
                case .failure(let error):
                    let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                    if message == "Cancelled" {
                        finishJob(kind: "flux_prompt", jobID: jobID, success: false, error: "Cancelled")
                    } else {
                        lastError = message
                        finishJob(kind: "flux_prompt", jobID: jobID, success: false, error: message)
                    }
                }
            }
        )
        return jobID
    }

    private func finishJob(kind: String, jobID: String, success: Bool, error: String) {
        isBusy = false
        activeKind = ""
        activeJobID = ""
        onJobFinished?(kind, success, error)
    }
}
