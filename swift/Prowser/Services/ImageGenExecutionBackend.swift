import Foundation

/// User preference for MFLUX execution (persistent Python pipelines vs per-job CLI).
enum ImageGenExecutionBackend: String, Equatable {
    case optimized
    case mfluxCLI = "mflux_cli"

    @MainActor
    static func from(config: AppConfig) -> ImageGenExecutionBackend {
        let raw = config.string(forKey: "imagegen_execution_backend", default: "optimized")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw == ImageGenExecutionBackend.mfluxCLI.rawValue ? .mfluxCLI : .optimized
    }
}
