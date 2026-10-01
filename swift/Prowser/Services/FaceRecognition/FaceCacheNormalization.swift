import CryptoKit
import Foundation

/// Path keys for face cache (port of `faces/face_cache.py`).
enum FaceCacheNormalization {
    static func normalizePathForFaceCache(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    static func candidateIndexKeys(path: String) -> [String] {
        let expanded = (path as NSString).expandingTildeInPath
        let resolved = URL(fileURLWithPath: expanded).standardizedFileURL.path
        let real = (expanded as NSString).resolvingSymlinksInPath
        if real == resolved {
            return [resolved]
        }
        return [resolved, real]
    }

    static func pathHash(_ pathKey: String) -> String {
        let digest = SHA256.hash(data: Data(pathKey.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(24).description
    }
}
