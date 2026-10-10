import Foundation

/// Merge LoRA path keys from snapshotted values (port of `enrich_values_with_worker_lora_fields`).
enum LoRAWorkerPayloadEnrich {
    static let mergeKeys = ImageGenLoraWorkerPayloadEnrich.mergeKeys

    @MainActor
    static func enrich(
        plugin: ImageGenPluginDescriptor,
        values: [String: Any],
        config: AppConfig
    ) async throws -> [String: Any] {
        var out = values
        if plugin.loraHostID == nil { return out }
        if ImageGenLoraWorkerPayloadEnrich.payloadHasResolvedLoraPaths(out),
           out[ImageGenJobValuesSnapshot.snapshottedKey] as? Bool == true {
            ImageGenLoraTriggerPromptGuard.applyForRun(&out)
            return out
        }
        let lc = LoRACatalogStore(paths: config.profilePaths).load()
        try await LoRAJobSnapshot.snapshotLoraForJob(
            values: &out,
            pipelineID: plugin.pipelineID,
            lc: lc,
            config: config
        )
        ImageGenLoraTriggerPromptGuard.applyForRun(&out)
        return out
    }
}
