import Foundation

/// Container for Python subprocess bridges (Milestone 6).
@Observable
@MainActor
final class WorkerServices {
    let modelTasks: ModelTasksBridge
    let foregroundModelTasks: ModelTasksBridge
    let imageGenRegistry: ImageGenRegistryBridge
    let clip: CLIPBridge
    let chat: ChatBridge
    let face: FaceBridge
    let similaritySearch: SimilaritySearchBridge
    let personSearch: PersonSearchBridge
    let whisper: WhisperBridge

    private(set) var pythonAvailable = false

    init(profilePath: String?) {
        modelTasks = ModelTasksBridge(profilePath: profilePath)
        foregroundModelTasks = ModelTasksBridge(profilePath: profilePath)
        imageGenRegistry = ImageGenRegistryBridge(profilePath: profilePath)
        clip = CLIPBridge(profilePath: profilePath)
        chat = ChatBridge(profilePath: profilePath)
        face = FaceBridge(profilePath: profilePath)
        similaritySearch = SimilaritySearchBridge(profilePath: profilePath)
        personSearch = PersonSearchBridge(profilePath: profilePath)
        whisper = WhisperBridge(profilePath: profilePath)
        pythonAvailable = modelTasks.isAvailable
    }

    func reloadSettings(config: AppConfig) {
        clip.reloadSettings(from: config)
    }

    func onDirectoryLoaded(_ directory: String?) {
        guard let directory else { return }
        clip.restartWithPriorityDirectory(directory)
    }

    func shutdown() {
        modelTasks.shutdown()
        foregroundModelTasks.shutdown()
        imageGenRegistry.shutdown()
        clip.shutdown()
        chat.shutdown()
        face.shutdown()
        similaritySearch.shutdown()
        personSearch.shutdown()
        whisper.shutdown()
    }
}
