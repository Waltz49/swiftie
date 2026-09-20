import CryptoKit
import Foundation

/// Path keys for face cache (port of `faces/face_cache.py`).
enum FaceCacheNormalization {
    static func normalizePathForFaceCache(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    static func candidateIndexKeys(path: String) -> [String] {
        var keys: [String] = []
        let expanded = (path as NSString).expandingTildeInPath
        if let resolved = try? URL(fileURLWithPath: expanded).standardizedFileURL.path {
            keys.append(resolved)
        }
        let real = (expanded as NSString).resolvingSymlinksInPath
        if !keys.contains(real) { keys.append(real) }
        return keys
    }

    static func pathHash(_ pathKey: String) -> String {
        let digest = SHA256.hash(data: Data(pathKey.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(24).description
    }
}
