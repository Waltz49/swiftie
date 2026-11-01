import Foundation

@MainActor
enum ChatCopy {
    static func lmStudioUnavailableMessage(config: AppConfig) -> String {
        let host = config.string(forKey: "caption_lms_host").trimmingCharacters(in: .whitespacesAndNewlines)
        let displayHost = host.isEmpty ? "localhost:1234" : host
        return """
        LM Studio is not available at \(displayHost).

        Start LM Studio, enable the local API server, and load a model.
        """
    }
}
