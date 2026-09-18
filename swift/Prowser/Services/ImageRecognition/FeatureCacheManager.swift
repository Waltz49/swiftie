import CryptoKit
import Foundation

/// Swift-native CNN/CLIP feature cache (port of `cache/feature_cache_manager.py`).
final class FeatureCacheManager: @unchecked Sendable {
    private let cacheRoot: URL
    private let resnetModelSafe: String
    private let clipModelSafe: String
    private let lock = NSLock()

    private var cnnCache: [String: (feature: [Float]?, mtime: Double, size: Int)] = [:]
    private var clipCache: [String: (feature: [Float]?, mtime: Double, size: Int)] = [:]
    private var visionCache: [String: (feature: [Float]?, mtime: Double, size: Int)] = [:]
    private var cnnDirtyDirs: Set<String> = []
    private var clipDirtyDirs: Set<String> = []
    private var visionDirtyDirs: Set<String> = []
    private var cnnLoadedDirs: Set<String> = []
    private var clipLoadedDirs: Set<String> = []
    private var visionLoadedDirs: Set<String> = []

    private lazy var cnnCacheDir: URL = {
        cacheRoot.appendingPathComponent("cnn_features_\(resnetModelSafe)", isDirectory: true)
    }()

    private lazy var clipCacheDir: URL = {
        cacheRoot.appendingPathComponent("clip_features_\(clipModelSafe)", isDirectory: true)
    }()

    private lazy var cnnIndexFile: URL = {
        cacheRoot.appendingPathComponent("cnn_index_\(resnetModelSafe).json")
    }()

    private lazy var clipIndexFile: URL = {
        cacheRoot.appendingPathComponent("clip_index_\(clipModelSafe).json")
    }()

    private lazy var visionCacheDir: URL = {
        cacheRoot.appendingPathComponent("vision_features_apple", isDirectory: true)
    }()

    private lazy var visionIndexFile: URL = {
        cacheRoot.appendingPathComponent("vision_index_apple.json")
    }()

    init(cacheRoot: URL, resnetModel: String, clipModelName: String) {
        self.cacheRoot = cacheRoot
        self.resnetModelSafe = resnetModel.replacingOccurrences(of: "/", with: "_")
        self.clipModelSafe = clipModelName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        try? FileManager.default.createDirectory(at: cnnCacheDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: clipCacheDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: visionCacheDir, withIntermediateDirectories: true)
    }

    func getVision(path: String, mtime: Double, size: Int) -> [Float]? {
        let key = cacheKey(path)
        lock.lock()
        defer { lock.unlock() }
        loadDirectoryIfNeeded(cacheType: .vision, path: path)
        if let entry = visionCache[key], entry.mtime == mtime, entry.size == size {
            return entry.feature
        }
        return nil
    }

    func setVision(path: String, mtime: Double, size: Int, feature: [Float]?) {
        let key = cacheKey(path)
        let dirHash = directoryHash(path)
        lock.lock()
        visionCache[key] = (feature, mtime, size)
        visionDirtyDirs.insert(dirHash)
        lock.unlock()
    }

    func getCNN(path: String, mtime: Double, size: Int) -> [Float]? {
        let key = cacheKey(path)
        lock.lock()
        defer { lock.unlock() }
        loadDirectoryIfNeeded(cacheType: .cnn, path: path)
        if let entry = cnnCache[key], entry.mtime == mtime, entry.size == size {
            return entry.feature
        }
        return nil
    }

    func setCNN(path: String, mtime: Double, size: Int, feature: [Float]?) {
        let key = cacheKey(path)
        let dirHash = directoryHash(path)
        lock.lock()
        cnnCache[key] = (feature, mtime, size)
        cnnDirtyDirs.insert(dirHash)
        lock.unlock()
    }

    func getCLIP(path: String, mtime: Double, size: Int) -> [Float]? {
        let key = cacheKey(path)
        lock.lock()
        defer { lock.unlock() }
        loadDirectoryIfNeeded(cacheType: .clip, path: path)
        if let entry = clipCache[key], entry.mtime == mtime, entry.size == size {
            return entry.feature
        }
        return nil
    }

    func setCLIP(path: String, mtime: Double, size: Int, feature: [Float]?) {
        let key = cacheKey(path)
        let dirHash = directoryHash(path)
        lock.lock()
        clipCache[key] = (feature, mtime, size)
        clipDirtyDirs.insert(dirHash)
        lock.unlock()
    }

    func flushCaches() {
        lock.lock()
        let cnnDirs = cnnDirtyDirs
        let clipDirs = clipDirtyDirs
        let visionDirs = visionDirtyDirs
        lock.unlock()
        if !cnnDirs.isEmpty { saveCNN(dirtyDirs: cnnDirs) }
        if !clipDirs.isEmpty { saveCLIP(dirtyDirs: clipDirs) }
        if !visionDirs.isEmpty { saveVision(dirtyDirs: visionDirs) }
    }

    private enum CacheType { case cnn, clip, vision }

    private func loadDirectoryIfNeeded(cacheType: CacheType, path: String) {
        let dirHash = directoryHash(path)
        switch cacheType {
        case .cnn:
            guard !cnnLoadedDirs.contains(dirHash) else { return }
            loadDirectoryFile(cacheType: .cnn, dirHash: dirHash)
            cnnLoadedDirs.insert(dirHash)
        case .clip:
            guard !clipLoadedDirs.contains(dirHash) else { return }
            loadDirectoryFile(cacheType: .clip, dirHash: dirHash)
            clipLoadedDirs.insert(dirHash)
        case .vision:
            guard !visionLoadedDirs.contains(dirHash) else { return }
            loadDirectoryFile(cacheType: .vision, dirHash: dirHash)
            visionLoadedDirs.insert(dirHash)
        }
    }

    private func cacheDirectory(for cacheType: CacheType) -> URL {
        switch cacheType {
        case .cnn: return cnnCacheDir
        case .clip: return clipCacheDir
        case .vision: return visionCacheDir
        }
    }

    private func loadDirectoryFile(cacheType: CacheType, dirHash: String) {
        let file = cacheDirectory(for: cacheType).appendingPathComponent("\(dirHash).fcache")
        guard let data = try? Data(contentsOf: file),
              let payload = try? JSONDecoder().decode(DirectoryCacheFile.self, from: data) else { return }
        for item in payload.items {
            let key = cacheKey(item.path)
            switch cacheType {
            case .cnn:
                cnnCache[key] = (item.feature, item.mtime, item.size)
            case .clip:
                clipCache[key] = (item.feature, item.mtime, item.size)
            case .vision:
                visionCache[key] = (item.feature, item.mtime, item.size)
            }
        }
    }

    private func saveCNN(dirtyDirs: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        for dirHash in dirtyDirs {
            persistDirectory(cacheType: .cnn, dirHash: dirHash)
        }
        cnnDirtyDirs.subtract(dirtyDirs)
    }

    private func saveCLIP(dirtyDirs: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        for dirHash in dirtyDirs {
            persistDirectory(cacheType: .clip, dirHash: dirHash)
        }
        clipDirtyDirs.subtract(dirtyDirs)
    }

    private func saveVision(dirtyDirs: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        for dirHash in dirtyDirs {
            persistDirectory(cacheType: .vision, dirHash: dirHash)
        }
        visionDirtyDirs.subtract(dirtyDirs)
    }

    private func persistDirectory(cacheType: CacheType, dirHash: String) {
        let cacheDict: [String: (feature: [Float]?, mtime: Double, size: Int)]
        switch cacheType {
        case .cnn: cacheDict = cnnCache
        case .clip: cacheDict = clipCache
        case .vision: cacheDict = visionCache
        }
        var items: [DirectoryCacheItem] = []
        for (key, entry) in cacheDict where directoryHash(key) == dirHash {
            items.append(DirectoryCacheItem(path: key, mtime: entry.mtime, size: entry.size, feature: entry.feature))
        }
        guard !items.isEmpty else { return }
        let payload = DirectoryCacheFile(items: items)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let file = cacheDirectory(for: cacheType).appendingPathComponent("\(dirHash).fcache")
        try? data.write(to: file, options: .atomic)
        updateIndex(cacheType: cacheType, items: items)
    }

    private func updateIndex(cacheType: CacheType, items: [DirectoryCacheItem]) {
        let indexURL: URL
        switch cacheType {
        case .cnn: indexURL = cnnIndexFile
        case .clip: indexURL = clipIndexFile
        case .vision: indexURL = visionIndexFile
        }
        var index: [String: IndexEntry] = [:]
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([String: IndexEntry].self, from: data) {
            index = decoded
        }
        for item in items {
            index[item.path] = IndexEntry(
                dirHash: directoryHash(item.path),
                mtime: item.mtime,
                size: item.size
            )
        }
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    private struct DirectoryCacheItem: Codable {
        let path: String
        let mtime: Double
        let size: Int
        let feature: [Float]?
    }

    private struct DirectoryCacheFile: Codable {
        let items: [DirectoryCacheItem]
    }

    private struct IndexEntry: Codable {
        let dirHash: String
        let mtime: Double
        let size: Int
    }

    private func cacheKey(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func directoryHash(_ path: String) -> String {
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
        let digest = SHA256.hash(data: Data(dir.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func clearAll(at cacheRoot: URL) throws {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil) else { return }
        for url in contents where url.lastPathComponent != "models" {
            try? fm.removeItem(at: url)
        }
    }
}
