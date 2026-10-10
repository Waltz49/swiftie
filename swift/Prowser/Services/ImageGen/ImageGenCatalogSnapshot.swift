import Foundation

/// Frozen plugin dialog metadata (field layouts + merged defaults). Runtime source of truth
/// for dialog fields; regenerate via `Scripts/generate_imagegen_catalog_snapshot.sh` when the
/// Python reference plugins change (build/dev only — the app does not call Python at runtime).
enum ImageGenCatalogSnapshot {
    private static let resourceName = "ImageGenPluginCatalogSnapshot"

    private static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle.main
        #endif
    }

    static func loadPlugins() -> [[String: Any]] {
        guard let url = resourceBundle.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = root["plugins"] as? [[String: Any]] else {
            return []
        }
        return plugins
    }

    static func pluginDictionary(pluginID: String) -> [String: Any]? {
        let id = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        return loadPlugins().first { ($0["plugin_id"] as? String) == id }
    }
}
