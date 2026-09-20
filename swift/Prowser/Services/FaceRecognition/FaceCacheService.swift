import CryptoKit
import Foundation

/// Per-image face embeddings under shared `face_cache/` (port of `faces/face_cache.py`).
final class FaceCacheService: @unchecked Sendable {
    private let cacheRoot: URL
    private let lock = NSLock()
    private var indexMemory: [String: IndexEntry]?
    private var writesSincePersist = 0
    private static let persistInterval = 50

    struct IndexEntry: Codable {
        var mtime: Double
        var size: Int
        var md5: String?
    }

    init(profile: ProfilePaths) {
        cacheRoot = profile.sharedFaceCacheDirectory
        try? FileManager.default.createDirectory(
            at: cacheRoot.appendingPathComponent("data", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    func hasCachedFaces(imagePath: String) -> Bool {
        getEncodings(imagePath: imagePath) != nil
    }

    func getEncodings(imagePath: String, mtime: Double? = nil, size: Int? = nil) -> [[Double]]? {
        lock.lock()
        defer { lock.unlock() }
        let index = loadIndex()
        var matchedKey: String?
        var entry: IndexEntry?
        for key in FaceCacheNormalization.candidateIndexKeys(path: imagePath) {
            if let e = index[key] {
                matchedKey = key
                entry = e
                break
            }
        }
        guard let entry, let matchedKey else { return nil }
        if let mtime, entry.mtime != mtime { return nil }
        if let size, entry.size != size { return nil }
        let dataPath = dataPathForIndexKey(matchedKey)
        guard let data = try? Data(contentsOf: dataPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let encodings = json["encodings"] as? [[Double]] else { return nil }
        return encodings
    }

    func setEncodings(imagePath: String, encodings: [[Double]], mtime: Double?, size: Int?) {
        let key = FaceCacheNormalization.normalizePathForFaceCache(imagePath)
        var m = mtime
        var s = size
        if m == nil || s == nil {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: imagePath),
               let mt = attrs[.modificationDate] as? Date,
               let sz = attrs[.size] as? Int {
                m = mt.timeIntervalSince1970
                s = sz
            } else {
                m = 0
                s = 0
            }
        }
        let md5 = Self.fileMD5(path: imagePath)
        let dataPath = dataPath(for: imagePath)
        let payload: [String: Any] = ["encodings": encodings]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: dataPath, options: .atomic)
        }
        lock.lock()
        var index = loadIndex()
        var entry = IndexEntry(mtime: m!, size: s!, md5: md5)
        index[key] = entry
        indexMemory = index
        writesSincePersist += 1
        if writesSincePersist >= Self.persistInterval {
            persistIndex(index)
            writesSincePersist = 0
        }
        lock.unlock()
    }

    func flushIndex() {
        lock.lock()
        if let index = indexMemory {
            persistIndex(index)
            writesSincePersist = 0
        }
        lock.unlock()
    }

    func clearAll() {
        lock.lock()
        indexMemory = [:]
        lock.unlock()
        let fm = FileManager.default
        let dataDir = cacheRoot.appendingPathComponent("data", isDirectory: true)
        if let files = try? fm.contentsOfDirectory(at: dataDir, includingPropertiesForKeys: nil) {
            for f in files { try? fm.removeItem(at: f) }
        }
        let sampleThumbs = cacheRoot.appendingPathComponent("sample_thumbs", isDirectory: true)
        if let files = try? fm.contentsOfDirectory(at: sampleThumbs, includingPropertiesForKeys: nil) {
            for f in files { try? fm.removeItem(at: f) }
        }
        try? fm.removeItem(at: indexFile)
    }

    private var indexFile: URL { cacheRoot.appendingPathComponent("index.json") }

    private func loadIndex() -> [String: IndexEntry] {
        if let indexMemory { return indexMemory }
        guard let data = try? Data(contentsOf: indexFile),
              let raw = try? JSONDecoder().decode([String: IndexEntry].self, from: data) else {
            indexMemory = [:]
            return [:]
        }
        indexMemory = raw
        return raw
    }

    private func persistIndex(_ index: [String: IndexEntry]) {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexFile, options: .atomic)
    }

    private func dataPath(for imagePath: String) -> URL {
        let key = FaceCacheNormalization.normalizePathForFaceCache(imagePath)
        let hash = FaceCacheNormalization.pathHash(key)
        return cacheRoot.appendingPathComponent("data/\(hash).json")
    }

    private func dataPathForIndexKey(_ key: String) -> URL {
        let hash = FaceCacheNormalization.pathHash(key)
        return cacheRoot.appendingPathComponent("data/\(hash).json")
    }

    private static func fileMD5(path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
