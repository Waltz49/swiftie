import Foundation

enum GenerationTimingKeyBuilder {
    struct Result {
        var key: GenerationTimingKey?
        var averageSeconds: Double?
    }

    static func build(pluginID: String, values: [String: Any], dataDirectory: URL) -> Result {
        guard let plugin = ImageGenPluginCatalog.plugin(pluginID: pluginID) else {
            return Result(key: nil, averageSeconds: nil)
        }
        guard let key = makeKey(plugin: plugin, values: values) else {
            return Result(key: nil, averageSeconds: nil)
        }
        let average = GenerationTimingStats.lookupAverage(key: key, dataDirectory: dataDirectory)
        return Result(key: key, averageSeconds: average)
    }

    private static func makeKey(plugin: ImageGenPluginDescriptor, values: [String: Any]) -> GenerationTimingKey? {
        let hf = (values["hf_model_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = hf.contains("/") ? hf : plugin.hfModelID
        guard !modelID.isEmpty else { return nil }

        let steps = intValue(values["steps"]) ?? 0
        guard let width = intValue(values["width"]),
              let height = intValue(values["height"]),
              width > 0, height > 0 else {
            return nil
        }
        let quant = quantLabel(plugin: plugin, values: values)
        return GenerationTimingKey(
            modelID: modelID,
            steps: steps,
            width: width,
            height: height,
            quant: quant
        )
    }

    private static func quantLabel(plugin: ImageGenPluginDescriptor, values: [String: Any]) -> String {
        guard plugin.reportsQuantization else { return "" }
        let key = plugin.quantizeStatusKey
        let raw = values[key]
        if key == "mlx_tier" {
            let tier = (raw as? String ?? "q4").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch tier {
            case "q4": return "4"
            case "q8": return "8"
            case "bf16": return "16"
            default: return tier
            }
        }
        return intValue(raw).map { "\($0)" } ?? ""
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }
}
