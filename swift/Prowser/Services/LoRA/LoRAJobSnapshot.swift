import Foundation

/// Submit-time LoRA freeze (port of `job_values_snapshot._snapshot_lora_for_job`).
enum LoRAJobSnapshot {
    static let loraTriggerWordsKey = "mflux_lora_trigger_words"
    static let loraScalesByIDKey = "mflux_lora_scales_by_id"

    static func snapshotLoraForJob(
        values: inout [String: Any],
        pipelineID: String,
        lc: [String: Any],
        config: AppConfig
    ) async throws {
        let host = LoRAHostRegistry.hostForPipeline(pipelineID)
        let stack = effectiveLoraIDs(from: values, pipelineID: pipelineID)
        if stack.isEmpty {
            clearLoraKeys(&values, host: host, pipelineID: pipelineID)
            return
        }
        let catalog = LoRACatalog.mergedCatalog(lc: lc)
        var paths: [String] = []
        var scales: [Double] = []
        var triggers: [String] = []
        var scalesByID: [String: Double] = [:]
        for presetID in stack {
            guard let entry = LoRACatalog.getEntry(loraID: presetID, lc: lc) else {
                throw LoRAPathError.unknownPreset(presetID)
            }
            let path = try await LoRAPathResolver.resolvePath(presetID: presetID, catalog: catalog, config: config)
            paths.append(path)
            let scale = loraScale(for: values, presetID: presetID, entry: entry)
            scales.append(scale)
            scalesByID[presetID] = scale
            if let t = entry.triggerWord?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                triggers.append(t)
            }
        }
        values[loraTriggerWordsKey] = triggers
        values[loraScalesByIDKey] = scalesByID
        if host == LoRAHostRegistry.sd15 {
            values["mflux_lora"] = stack[0]
            values.removeValue(forKey: "mflux_lora_stack")
            values["sd15_lora_paths"] = paths
            values["sd15_lora_scales"] = scales
            values.removeValue(forKey: "mflux_lora_paths")
            values.removeValue(forKey: "mflux_lora_scales")
            values.removeValue(forKey: "sdxl_lora_paths")
            values.removeValue(forKey: "sdxl_lora_scales")
        } else if host == LoRAHostRegistry.sdxl {
            values["mflux_lora_stack"] = stack
            values.removeValue(forKey: "mflux_lora")
            values["sdxl_lora_paths"] = paths
            values["sdxl_lora_scales"] = scales
            values.removeValue(forKey: "mflux_lora_paths")
            values.removeValue(forKey: "mflux_lora_scales")
            values.removeValue(forKey: "sd15_lora_paths")
            values.removeValue(forKey: "sd15_lora_scales")
        } else {
            values["mflux_lora_stack"] = stack
            values.removeValue(forKey: "mflux_lora")
            values["mflux_lora_paths"] = paths
            values["mflux_lora_scales"] = scales
            values.removeValue(forKey: "sd15_lora_paths")
            values.removeValue(forKey: "sd15_lora_scales")
            values.removeValue(forKey: "sdxl_lora_paths")
            values.removeValue(forKey: "sdxl_lora_scales")
        }
    }

    static func effectiveLoraIDs(from values: [String: Any], pipelineID: String = "") -> [String] {
        _ = pipelineID
        let explicitStack = values.keys.contains("mflux_lora_stack")
        let stackRaw = values["mflux_lora_stack"]
        let legacy = values["mflux_lora"]

        var ids: [String] = []
        if let stack = stackRaw as? [Any] {
            for item in stack {
                let pid = LoRAPathResolver.normalizePresetID(item)
                if pid != "none", !ids.contains(pid) { ids.append(pid) }
            }
        } else if stackRaw != nil, !(stackRaw is NSNull) {
            if let empty = stackRaw as? [Any], empty.isEmpty {
                // explicit empty stack
            } else {
                let pid = LoRAPathResolver.normalizePresetID(stackRaw!)
                if pid != "none", !ids.contains(pid) { ids.append(pid) }
            }
        }

        if explicitStack { return ids }

        if ids.isEmpty, let legacy {
            let pid = LoRAPathResolver.normalizePresetID(legacy)
            if pid != "none" { ids.append(pid) }
        }
        return ids
    }

    private static func loraScale(for values: [String: Any], presetID: String, entry: LoRAEntry) -> Double {
        if let map = values["mflux_lora_scales_by_id"] as? [String: Any],
           let raw = map[presetID] {
            if let n = raw as? NSNumber { return n.doubleValue }
            if let d = raw as? Double { return d }
        }
        return entry.scale
    }

    private static func clearLoraKeys(_ values: inout [String: Any], host: String?, pipelineID: String) {
        values.removeValue(forKey: "mflux_lora_paths")
        values.removeValue(forKey: "mflux_lora_scales")
        values.removeValue(forKey: "sd15_lora_paths")
        values.removeValue(forKey: "sd15_lora_scales")
        values.removeValue(forKey: "sdxl_lora_paths")
        values.removeValue(forKey: "sdxl_lora_scales")
        values.removeValue(forKey: loraTriggerWordsKey)
        values.removeValue(forKey: loraScalesByIDKey)
        if host == LoRAHostRegistry.sd15 {
            values["mflux_lora"] = "none"
            values.removeValue(forKey: "mflux_lora_stack")
        } else {
            values["mflux_lora_stack"] = []
            values.removeValue(forKey: "mflux_lora")
        }
    }
}
