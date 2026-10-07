import Foundation

/// Placeholder until LoRA management is reimplemented.
@MainActor
final class LoRABridgeStub {
    var isAvailable: Bool { false }

    func shutdown() {}

    func choicesForPlugin(pluginID: String, values: [String: Any]) async throws -> LoRAPluginChoices {
        LoRAPluginChoices.unsupported()
    }

    func selectedDisplayText(pluginID: String, values: [String: Any]) async throws -> String {
        "Not implemented yet"
    }

    func updateEntryScales(pluginID: String, scalesByID: [String: Double]) async throws {}

    func matchExif(pluginID: String, exifLoraName: String) async throws -> [String: Any]? {
        nil
    }
}

struct LoRAChoice: Identifiable, Equatable {
    var presetID: String
    var label: String
    var id: String { presetID }
}

struct LoRAPluginChoices: Equatable {
    var unsupported: Bool
    var unsupportedLabel: String
    var stackMode: Bool
    var popupMode: Bool
    var choices: [LoRAChoice]
    var selectedIDs: [String]
    var scalesByID: [String: Double]

    static func unsupported() -> LoRAPluginChoices {
        LoRAPluginChoices(
            unsupported: true,
            unsupportedLabel: "Not implemented yet",
            stackMode: true,
            popupMode: false,
            choices: [],
            selectedIDs: [],
            scalesByID: [:]
        )
    }
}
