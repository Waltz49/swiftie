import Foundation

/// Flux-prompt AI during generation is not wired on WithGen yet.
@MainActor
final class FluxPromptTasksStub {
    private(set) var isReady = false
    private(set) var isBusy = false
    private(set) var activeJobID = ""
    private(set) var activeKind = ""
    private(set) var lastError = ""

    var isAvailable: Bool { false }

    var onFluxPromptChunk: ((String) -> Void)?
    var onFluxPromptReady: ((String) -> Void)?
    var onJobFinished: ((String, Bool, String) -> Void)?

    func cancel() {
        isBusy = false
        activeKind = ""
        activeJobID = ""
    }

    func shutdown() {}

    func startFluxPrompt(prompt: String, systemPrompt: String? = nil, imagePaths: [String] = []) throws -> String {
        throw BridgeError.pythonUnavailable
    }
}
