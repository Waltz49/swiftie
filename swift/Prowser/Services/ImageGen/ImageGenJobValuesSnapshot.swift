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
        normalizeEditSourcePaths(plugin: plugin, values: &out)
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

    /// Python ``_normalize_job_source_paths``: the submitted edit source list is
    /// authoritative; canonical paths must not leak from saved dialog settings.
    private static func normalizeEditSourcePaths(
        plugin: ImageGenPluginDescriptor,
        values: inout [String: Any]
    ) {
        guard plugin.function == "edit" else { return }
        let paths = ImageGenExifReferences.resolveSourceImagePaths(values)
        guard !paths.isEmpty else {
            values.removeValue(forKey: "source_image_path")
            values.removeValue(forKey: "source_image_paths")
            values.removeValue(forKey: "_canonical_source_image_paths")
            return
        }
        values["source_image_path"] = paths[0]
        values["source_image_paths"] = paths
        values["_canonical_source_image_paths"] = paths
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
    case payload(String)

    var errorDescription: String? {
        switch self {
        case .unknownPlugin(let id):
            return "Unknown image generation plugin: \(id)"
        case .payload(let message):
            return message
        }
    }
}
