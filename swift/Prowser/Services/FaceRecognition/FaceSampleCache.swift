import CryptoKit
import Foundation

/// Sample face thumbs under shared `face_cache/sample_thumbs/` (port of `faces/face_sample_cache.py`).
enum FaceSampleCache {
    private static let lock = NSLock()

    static func embeddingToFaceKey(_ embedding: [Double]) -> String? {
        guard embedding.count == 128 else { return nil }
        var data = Data(count: 128 * MemoryLayout<Double>.size)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: Double.self) else { return }
            for i in 0..<128 { base[i] = embedding[i] }
        }
        let digest = SHA256.hash(data: data)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func sampleThumbsRoot(profile: ProfilePaths) -> URL {
        profile.sharedFaceCacheDirectory.appendingPathComponent("sample_thumbs", isDirectory: true)
    }

    /// Read order matches Python `ensure_face_sample_thumbnail` (`fk`, then `fk_L`).
    static func faceKeyReadCandidates(faceKey: String?) -> [String?] {
        guard let faceKey, !faceKey.isEmpty else { return [nil] }
        if faceKey.hasSuffix("_L") {
            let base = String(faceKey.dropLast(2))
            return [base, faceKey]
        }
        return [faceKey, "\(faceKey)_L"]
    }

    static func cachedPNGPath(
        profile: ProfilePaths,
        imagePath: String,
        faceKey: String?
    ) -> URL? {
        let fm = FileManager.default
        let imagesDir = imagesDirectory(profile: profile)
        for pathVariant in pathVariantsForCacheLookup(imagePath) {
            for fk in faceKeyReadCandidates(faceKey: faceKey) {
                let key = indexKey(path: pathVariant, faceKey: fk)
                let file = imagesDir.appendingPathComponent("\(FaceCacheNormalization.pathHash(key)).png")
                if fm.fileExists(atPath: file.path) {
                    return file
                }
            }
        }
        return nil
    }

    static func cachedPNGByFaceKey(profile: ProfilePaths, faceKey: String) -> URL? {
        let dir = byFaceKeyDirectory(profile: profile)
        for fk in faceKeyReadCandidates(faceKey: faceKey).compactMap({ $0 }) {
            let file = dir.appendingPathComponent("\(fk).png")
            if FileManager.default.fileExists(atPath: file.path) {
                return file
            }
        }
        return nil
    }

    static func writePNG(
        profile: ProfilePaths,
        imagePath: String,
        faceKey: String?,
        pngData: Data
    ) {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: imagesDirectory(profile: profile), withIntermediateDirectories: true)
        try? fm.createDirectory(at: byFaceKeyDirectory(profile: profile), withIntermediateDirectories: true)

        let key = indexKey(path: imagePath, faceKey: faceKey)
        let thumbURL = imagesDirectory(profile: profile)
            .appendingPathComponent("\(FaceCacheNormalization.pathHash(key)).png")
        try? pngData.write(to: thumbURL, options: .atomic)

        var mtime: Double = 0
        var size: Int = 0
        if !imagePath.isEmpty, let attrs = try? fm.attributesOfItem(atPath: imagePath) {
            mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            size = (attrs[.size] as? Int) ?? 0
        }
        var index = loadIndex(profile: profile)
        index[key] = ["mtime": mtime, "size": Double(size)]
        saveIndex(profile: profile, index: index)

        if let faceKey {
            let byKey = byFaceKeyDirectory(profile: profile).appendingPathComponent("\(faceKey).png")
            try? pngData.write(to: byKey, options: .atomic)
        }
    }

    private static func pathVariantsForCacheLookup(_ imagePath: String) -> [String] {
        if imagePath.isEmpty { return [""] }
        var keys = FaceCacheNormalization.candidateIndexKeys(path: imagePath)
        let norm = FaceCacheNormalization.normalizePathForFaceCache(imagePath)
        if !keys.contains(norm) { keys.append(norm) }
        return keys
    }

    private static func indexKey(path: String, faceKey: String?) -> String {
        let pk = path.isEmpty ? "" : FaceCacheNormalization.normalizePathForFaceCache(path)
        if let faceKey, !faceKey.isEmpty {
            return "\(pk)::\(faceKey)"
        }
        return pk
    }

    private static func imagesDirectory(profile: ProfilePaths) -> URL {
        sampleThumbsRoot(profile: profile).appendingPathComponent("images", isDirectory: true)
    }

    private static func byFaceKeyDirectory(profile: ProfilePaths) -> URL {
        sampleThumbsRoot(profile: profile).appendingPathComponent("by_face_key", isDirectory: true)
    }

    private static func indexURL(profile: ProfilePaths) -> URL {
        sampleThumbsRoot(profile: profile).appendingPathComponent("index.json")
    }

    private static func loadIndex(profile: ProfilePaths) -> [String: [String: Double]] {
        guard let data = try? Data(contentsOf: indexURL(profile: profile)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Double]] else {
            return [:]
        }
        return json
    }

    private static func saveIndex(profile: ProfilePaths, index: [String: [String: Double]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: index) else { return }
        try? data.write(to: indexURL(profile: profile), options: .atomic)
    }
}
