import Foundation

/// Field keys from ``ImageGenPluginCatalogSnapshot`` (Python ``field_specs`` / EXIF gating).
enum ImageGenExifPluginFields {
    private static var keysByPluginID: [String: Set<String>] = loadFieldKeysByPluginID()

    static func reportsGuidance(pluginID: String) -> Bool {
        keysByPluginID[pluginID]?.contains("guidance_scale") == true
    }

    static func reportsQuantization(plugin: ImageGenPluginDescriptor) -> Bool {
        guard plugin.reportsQuantization else { return false }
        return keysByPluginID[plugin.pluginID]?.contains(plugin.quantizeStatusKey) == true
    }

    static func guidanceForExif(plugin: ImageGenPluginDescriptor, values: [String: Any]) -> Double? {
        guard reportsGuidance(pluginID: plugin.pluginID) else { return nil }
        return doubleValue(values["guidance_scale"])
    }

    static func quantizationForExif(plugin: ImageGenPluginDescriptor, values: [String: Any]) -> Int? {
        guard reportsQuantization(plugin: plugin) else { return nil }
        let key = plugin.quantizeStatusKey
        if key == "mlx_tier" {
            let tier = (values[key] as? String ?? "q4").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch tier {
            case "q4": return 4
            case "q8": return 8
            case "bf16": return 16
            default:
                if let n = Int(tier) { return n }
                return nil
            }
        }
        return intValue(values[key])
    }

    /// Job status / hover tooltip quant digits (Python ``quantize_status_value``).
    static func quantizeStatusLabel(plugin: ImageGenPluginDescriptor, values: [String: Any]) -> String? {
        guard reportsQuantization(plugin: plugin) else { return nil }
        let key = plugin.quantizeStatusKey
        let raw = values[key]
        if key == "mlx_tier" {
            let tier = (raw as? String ?? "q4").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch tier {
            case "q4": return "4"
            case "q8": return "8"
            case "bf16": return "16"
            default: return tier.isEmpty ? nil : tier
            }
        }
        return intValue(raw).map { "\($0)" }
    }

    private static func loadFieldKeysByPluginID() -> [String: Set<String>] {
        guard let url = ProwserResourceBundle.url(forResource: "ImageGenPluginCatalogSnapshot", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = root["plugins"] as? [[String: Any]] else {
            return [:]
        }
        var out: [String: Set<String>] = [:]
        for raw in plugins {
            guard let pluginID = raw["plugin_id"] as? String else { continue }
            let layout = raw["field_layout"] as? [[String: Any]] ?? []
            out[pluginID] = Set(collectFieldKeys(in: layout))
        }
        return out
    }

    private static func collectFieldKeys(in nodes: [[String: Any]]) -> [String] {
        var keys: [String] = []
        for node in nodes {
            if let spec = node["spec"] as? [String: Any], let key = spec["key"] as? String {
                keys.append(key)
            }
            if let children = node["children"] as? [[String: Any]] {
                keys.append(contentsOf: collectFieldKeys(in: children))
            }
        }
        return keys
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String, let i = Int(s) { return i }
        return nil
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let n = any as? Double { return n }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String, let d = Double(s) { return d }
        if let i = any as? Int { return Double(i) }
        return nil
    }
}
