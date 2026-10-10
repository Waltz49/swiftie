import Foundation

/// Load/save `lora_catalog.json` (port of `lora_catalog_store.py`).
@MainActor
final class LoRACatalogStore {
    private let paths: ProfilePaths
    private var cacheMTime: Date?
    private var cacheData: [String: Any]?

    init(paths: ProfilePaths) {
        self.paths = paths
    }

    func catalogFileURL() -> URL { paths.loraCatalogFile }

    func load() -> [String: Any] {
        let path = catalogFileURL()
        let mtime = (try? path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        if let cached = cacheData, let cacheMTime, let mtime, cacheMTime == mtime {
            return cached
        }
        var data: [String: Any] = [:]
        if let raw = readJSON(path: path) {
            let migrated = LoRACatalogSettings.migrateCatalogIfNeeded(raw)
            data = migrated.catalog
            if migrated.changed {
                save(data)
            }
        } else {
            data = LoRACatalogSettings.migrateCatalog([:])
            save(data)
        }
        cacheData = data
        cacheMTime = (try? path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        return data
    }

    func save(_ lc: [String: Any]) {
        let payload = LoRACatalogSettings.migrateCatalog(lc)
        let path = catalogFileURL()
        atomicWriteJSON(path: path, payload: payload)
        cacheData = payload
        cacheMTime = (try? path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    }

    func invalidateCache() {
        cacheData = nil
        cacheMTime = nil
    }

    private func readJSON(path: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private func atomicWriteJSON(path: URL, payload: [String: Any]) {
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = path.deletingPathExtension().appendingPathExtension("json.tmp")
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: temp, options: .atomic)
        if FileManager.default.fileExists(atPath: path.path) {
            try? FileManager.default.removeItem(at: path)
        }
        try? FileManager.default.moveItem(at: temp, to: path)
    }
}
