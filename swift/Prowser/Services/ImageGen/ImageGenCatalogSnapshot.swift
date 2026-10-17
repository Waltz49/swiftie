import Foundation

/// Frozen plugin dialog metadata (field layouts + merged defaults). Runtime source of truth
/// for dialog fields; regenerate via `Scripts/generate_imagegen_catalog_snapshot.sh` when the
/// Python reference plugins change (build/dev only — the app does not call Python at runtime).
@MainActor
enum ImageGenCatalogSnapshot {
    private static let resourceName = "ImageGenPluginCatalogSnapshot"

    private static var cachedPlugins: [[String: Any]]?
    private static var cachedPluginByID: [String: [String: Any]] = [:]

    private static var resourceBundle: Bundle { ProwserResourceBundle.bundle }

    static func loadPlugins() -> [[String: Any]] {
        if let cachedPlugins { return cachedPlugins }
        guard let url = resourceBundle.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = root["plugins"] as? [[String: Any]] else {
            cachedPlugins = []
            return []
        }
        cachedPlugins = plugins
        var index: [String: [String: Any]] = [:]
        for raw in plugins {
            if let id = raw["plugin_id"] as? String {
                index[id] = raw
            }
        }
        cachedPluginByID = index
        return plugins
    }

    static func pluginDictionary(pluginID: String) -> [String: Any]? {
        let id = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        if cachedPlugins == nil {
            _ = loadPlugins()
        }
        return cachedPluginByID[id]
    }
}
