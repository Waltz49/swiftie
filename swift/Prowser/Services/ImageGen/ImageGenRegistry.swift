import Foundation

/// Image-generation registry surface (plugins, payloads, queue views, EXIF helpers).
@MainActor
protocol ImageGenRegistry: AnyObject {
    var isAvailable: Bool { get }
    var lastError: String { get }
    func shutdown()

    func listPlugins(
        function: String?,
        savedValues: [String: Any]?,
        availability: ImageGenPluginListAvailability
    ) async throws -> [[String: Any]]
    func buildPayload(
        pluginID: String,
        values: [String: Any],
        outputPath: String,
        applyImageExit: Bool
    ) async throws -> [String: Any]
    func normalizeValues(pluginID: String, values: [String: Any], mode: String) async throws -> [String: Any]
    func materializeSteps(pluginID: String, values: [String: Any], copies: Int) async throws -> [[String: Any]]
}

extension ImageGenRegistry {
    func listPlugins() async throws -> [[String: Any]] {
        try await listPlugins(function: nil, savedValues: nil, availability: .full)
    }

    func listPlugins(function: String?) async throws -> [[String: Any]] {
        try await listPlugins(function: function, savedValues: nil, availability: .full)
    }

    func listPlugins(function: String?, savedValues: [String: Any]?) async throws -> [[String: Any]] {
        try await listPlugins(function: function, savedValues: savedValues, availability: .full)
    }

    func buildPayload(
        pluginID: String,
        values: [String: Any],
        outputPath: String
    ) async throws -> [String: Any] {
        try await buildPayload(
            pluginID: pluginID,
            values: values,
            outputPath: outputPath,
            applyImageExit: true
        )
    }
}

