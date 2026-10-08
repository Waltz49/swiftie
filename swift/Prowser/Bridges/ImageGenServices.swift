import Foundation

/// Slim worker container for image generation (registry bridge only; no chat/CLIP Python workers).
@MainActor
final class ImageGenServices {
    let modelTasks = MfluxGenerationTasks()
    let imageGenRegistry: SwiftImageGenRegistry
    let lora: LoRABridgeStub
    let foregroundModelTasks = FluxPromptTasksStub()

    private(set) var pythonAvailable = false

    init(profilePath: String?, config: AppConfig) {
        MfluxToolchain.shared.bind(config: config)
        modelTasks.bind(config: config)
        imageGenRegistry = SwiftImageGenRegistry(config: config)
        lora = LoRABridgeStub()
        pythonAvailable = imageGenPythonPipelinesAvailable(config: config)
        if let environment = PythonLocator.resolve(profilePath: profilePath, config: config) {
            PythonLocator.reapOrphanWorkers(environment: environment)
        }
    }

    func reloadSettings(config: AppConfig) {
        MfluxToolchain.shared.bind(config: config)
        modelTasks.bind(config: config)
        imageGenRegistry.reloadSettings(config: config)
        pythonAvailable = imageGenPythonPipelinesAvailable(config: config)
    }

    func shutdown() {
        modelTasks.shutdown()
        imageGenRegistry.shutdown()
    }

    private func imageGenPythonPipelinesAvailable(config: AppConfig) -> Bool {
        ImageGenPythonBundle.rootURL() != nil
            && ImageGenPluginAvailability.venvPythonReady(config: config)
    }
}
