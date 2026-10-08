import Foundation

@MainActor
enum ImageGenPluginMetadata {
    static func maxGenerationDimension(pluginID: String) -> Int {
        if let snap = ImageGenCatalogSnapshot.pluginDictionary(pluginID: pluginID),
           let max = snap["max_generation_dimension"] as? Int {
            return max
        }
        return 1024
    }

    static func modelComment(pluginID: String) -> String {
        (ImageGenCatalogSnapshot.pluginDictionary(pluginID: pluginID)?["model_comment"] as? String) ?? ""
    }

    static func mergedDefaults(pluginID: String, saved: [String: Any]?) -> [String: Any] {
        let base = ImageGenCatalogSnapshot.pluginDictionary(pluginID: pluginID)?["merged_defaults"] as? [String: Any] ?? [:]
        guard let plugin = ImageGenPluginCatalog.plugin(pluginID: pluginID) else { return base }
        var out = base
        if let saved {
            for (key, value) in saved {
                out[key] = value
            }
        }
        out["hf_model_id"] = plugin.hfModelID
        if plugin.quantizeStatusKey != "mflux_quantize" {
            out.removeValue(forKey: "mflux_quantize")
        }
        return ImageGenMergedValues.clampDimensions(plugin: plugin, values: out)
    }
}

@MainActor
enum ImageGenMergedValues {
    static func clampDimensions(plugin: ImageGenPluginDescriptor, values: [String: Any]) -> [String: Any] {
        guard let mode = ImageGenPipelineModes.mode(pipelineID: plugin.pipelineID) else { return values }
        var out = values
        let maxSide = ImageGenPluginMetadata.maxGenerationDimension(pluginID: plugin.pluginID)
        if let w = intValue(out["width"]), let h = intValue(out["height"]), w > 0, h > 0 {
            let aligned = ImageGenDimMath.alignDimsForPipeline(
                pipelineID: plugin.pipelineID,
                width: w,
                height: h,
                effectiveMaxSide: maxSide
            )
            out["width"] = aligned.width
            out["height"] = aligned.height
        }
        let steps = intValue(out["steps"]) ?? mode.stepsDefault
        out["steps"] = max(mode.stepsMin, min(mode.stepsMax, steps))
        return out
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }
}
