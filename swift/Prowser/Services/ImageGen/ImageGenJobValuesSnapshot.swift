import Foundation

/// Port of ``job_values_snapshot.py`` (submit-time value freeze).
@MainActor
enum ImageGenJobValuesSnapshot {
    static let snapshottedKey = "_job_values_snapshotted"

    private static let jobQueueOnlyKeys: Set<String> = [
        "series_refinement",
        "series_prompt_refinement",
    ]

    static func jobValuesSnapshotted(_ values: [String: Any]) -> Bool {
        values[snapshottedKey] as? Bool == true
    }

    static func stripDialogLeakedJobQueueFlags(_ values: inout [String: Any]) {
        for key in jobQueueOnlyKeys {
            values.removeValue(forKey: key)
        }
    }

    static func snapshotJobValuesAtSubmit(
        plugin: ImageGenPluginDescriptor,
        values: [String: Any],
        config: AppConfig
    ) async throws -> [String: Any] {
        var out = values
        stripDialogLeakedJobQueueFlags(&out)
        let lc = LoRACatalogStore(paths: config.profilePaths).load()
        try await LoRAJobSnapshot.snapshotLoraForJob(
            values: &out,
            pipelineID: plugin.pipelineID,
            lc: lc,
            config: config
        )
        let pluginMax = ImageGenPluginMetadata.maxGenerationDimension(pluginID: plugin.pluginID)
        let effectiveMax = ImageGenDimLimits.effectiveMaxGenerationDimension(
            pluginMax: pluginMax,
            settings: config.rawSettings()
        )
        out["max_generation_dimension"] = effectiveMax
        out[snapshottedKey] = true
        return out
    }

    static func normalizeValues(
        pluginID: String,
        values: [String: Any],
        mode: String,
        config: AppConfig
    ) async throws -> [String: Any] {
        guard let plugin = ImageGenPluginCatalog.plugin(pluginID: pluginID) else {
            throw ImageGenRegistryError.unknownPlugin(pluginID)
        }
        var out = values
        switch mode {
        case "strip_dialog_flags":
            stripDialogLeakedJobQueueFlags(&out)
        case "snapshot":
            out = try await snapshotJobValuesAtSubmit(plugin: plugin, values: out, config: config)
        default:
            out = try await snapshotJobValuesAtSubmit(plugin: plugin, values: out, config: config)
        }
        return out
    }
}

enum ImageGenRegistryError: LocalizedError {
    case unknownPlugin(String)

    var errorDescription: String? {
        switch self {
        case .unknownPlugin(let id):
            return "Unknown image generation plugin: \(id)"
        }
    }
}
