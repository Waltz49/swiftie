import Foundation

/// Process-wide JSON cache so multiple ``LoRACatalogStore`` instances do not re-read/migrate the file.
private enum LoRACatalogJSONIO {
    static func read(path: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    static func write(path: URL, payload: [String: Any]) {
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

private enum LoRACatalogSharedFileCache {
    private static let lock = NSLock()
    static var path: String?
    static var mtime: Date?
    static var payload: [String: Any]?

    static func loadIfCurrent(fileURL: URL) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        let key = fileURL.path
        guard path == key,
              let fileMtime = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              let cachedMtime = mtime,
              cachedMtime == fileMtime,
              let payload else {
            return nil
        }
        return payload
    }

    static func store(_ payload: [String: Any], fileURL: URL) {
        lock.lock()
        path = fileURL.path
        mtime = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        self.payload = payload
        lock.unlock()
    }

    static func clear() {
        lock.lock()
        path = nil
        mtime = nil
        payload = nil
        lock.unlock()
    }
}

/// Load/save `lora_catalog.json` (port of `lora_catalog_store.py`).
@MainActor
final class LoRACatalogStore {
    private let paths: ProfilePaths
    private var cacheMTime: Date?
    private var cacheData: [String: Any]?
    private static var didScheduleDiskMaintenance = false

    init(paths: ProfilePaths) {
        self.paths = paths
    }

    func catalogFileURL() -> URL { paths.loraCatalogFile }

    func load() -> [String: Any] {
        let path = catalogFileURL()
        if let shared = LoRACatalogSharedFileCache.loadIfCurrent(fileURL: path) {
            cacheData = shared
            cacheMTime = (try? path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            scheduleDiskMaintenanceIfNeeded()
            return shared
        }
        let mtime = (try? path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        if let cached = cacheData, let cacheMTime, let mtime, cacheMTime == mtime {
            scheduleDiskMaintenanceIfNeeded()
            return cached
        }
        var data: [String: Any] = [:]
        if let raw = readJSON(path: path) {
            let migrated = LoRACatalogSettings.migrateCatalogIfNeeded(raw)
            data = migrated.catalog
            if migrated.changed {
                saveNormalized(data)
            }
        } else {
            data = LoRACatalogSettings.migrateCatalog([:])
            saveNormalized(data)
        }
        cacheData = data
        cacheMTime = (try? path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        LoRACatalogSharedFileCache.store(data, fileURL: path)
        scheduleDiskMaintenanceIfNeeded()
        return data
    }

    func save(_ lc: [String: Any]) {
        let payload = LoRACatalogSettings.migrateCatalog(lc)
        saveNormalized(payload)
    }

    func invalidateCache() {
        cacheData = nil
        cacheMTime = nil
        LoRACatalogSharedFileCache.clear()
    }

    private func saveNormalized(_ payload: [String: Any]) {
        let path = catalogFileURL()
        atomicWriteJSON(path: path, payload: payload)
        cacheData = payload
        cacheMTime = (try? path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        LoRACatalogSharedFileCache.store(payload, fileURL: path)
    }

    private func scheduleDiskMaintenanceIfNeeded() {
        guard !Self.didScheduleDiskMaintenance else { return }
        Self.didScheduleDiskMaintenance = true
        let fileURL = catalogFileURL()
        Task.detached(priority: .utility) {
            guard let raw = LoRACatalogJSONIO.read(path: fileURL) else { return }
            var lc = LoRACatalogSettings.migrateCatalogIfNeeded(raw).catalog
            guard LoRACatalogMaintenance.runDiskMaintenance(in: &lc) else { return }
            let normalized = LoRACatalogSettings.migrateCatalog(lc)
            LoRACatalogJSONIO.write(path: fileURL, payload: normalized)
            LoRACatalogSharedFileCache.store(normalized, fileURL: fileURL)
        }
    }

    private func readJSON(path: URL) -> [String: Any]? {
        LoRACatalogJSONIO.read(path: path)
    }

    private func atomicWriteJSON(path: URL, payload: [String: Any]) {
        LoRACatalogJSONIO.write(path: path, payload: payload)
    }
}