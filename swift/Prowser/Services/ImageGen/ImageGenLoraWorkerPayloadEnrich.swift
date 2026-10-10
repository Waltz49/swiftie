import Foundation

/// Resolves LoRA stack → path/scale keys via Python ``build_worker_payload`` (Swift builder stub).
enum ImageGenLoraWorkerPayloadEnrich {
    static let mergeKeys: [String] = [
        "mflux_lora_paths",
        "mflux_lora_scales",
        "sd15_lora_paths",
        "sd15_lora_scales",
        "sdxl_lora_paths",
        "sdxl_lora_scales",
        "mflux_lora_scales_by_id",
        "mflux_lora_trigger_words",
        "steps",
    ]

    static func payloadHasResolvedLoraPaths(_ values: [String: Any]) -> Bool {
        for key in ["mflux_lora_paths", "sd15_lora_paths", "sdxl_lora_paths"] {
            if let paths = values[key] as? [Any], !paths.isEmpty {
                return true
            }
        }
        return false
    }

    static func mergeLoraFields(from source: [String: Any], into values: inout [String: Any]) {
        let pathScaleKeys = Set(mergeKeys.filter { $0.hasSuffix("_paths") || $0.hasSuffix("_scales") })
        for key in mergeKeys {
            if let value = source[key] {
                values[key] = value
            } else if pathScaleKeys.contains(key) {
                values.removeValue(forKey: key)
            }
        }
    }

    static func enrichPayload(
        pluginID: String,
        payload: [String: Any],
        outputPath: String,
        applyImageExit: Bool,
        config: AppConfig
    ) async throws -> [String: Any] {
        guard let plugin = ImageGenPluginCatalog.plugin(pluginID: pluginID),
              plugin.loraHostID != nil else {
            return payload
        }
        return try await LoRAWorkerPayloadEnrich.enrich(
            plugin: plugin,
            values: payload,
            config: config
        )
    }
}
