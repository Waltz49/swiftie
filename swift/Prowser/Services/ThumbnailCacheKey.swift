import CryptoKit
import Foundation

/// Port of `cache/thumbnail_cache_key.py` — must stay in sync for disk cache reuse.
enum ThumbnailCacheKey {
    static func normalizeImagePath(_ imagePath: String) -> String {
        if imagePath.hasPrefix("/") { return imagePath }
        if imagePath.hasPrefix("~") {
            return (imagePath as NSString).expandingTildeInPath
        }
        return URL(fileURLWithPath: imagePath).standardizedFileURL.path
    }

    static func isPathInAppCacheDirectory(imagePath: String, appCacheDir: String) -> Bool {
        let absPath = URL(fileURLWithPath: imagePath).standardizedFileURL.path
        let absCache = URL(fileURLWithPath: appCacheDir).standardizedFileURL.path
        return absPath == absCache || absPath.hasPrefix(absCache + "/")
    }

    static func buildKeyMaterial(
        path: String,
        mtime: Int?,
        ignoreExifRotation: Bool,
        extra: String = ""
    ) -> String {
        var pathStr = path
        if let mtime {
            pathStr += "_\(mtime)"
        }
        pathStr += "_exif\(ignoreExifRotation ? 1 : 0)"
        if !extra.isEmpty {
            pathStr += "_\(extra)"
        }
        return pathStr
    }

    static func md5Hex(_ material: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func computeCacheKey(
        imagePath: String,
        appCacheDir: String,
        ignoreExifRotation: Bool,
        mtime: Int? = nil,
        extra: String = ""
    ) -> String {
        let pathStr = normalizeImagePath(imagePath)
        let resolvedMtime: Int?
        if isPathInAppCacheDirectory(imagePath: pathStr, appCacheDir: appCacheDir) {
            resolvedMtime = nil
        } else if let mtime {
            resolvedMtime = mtime
        } else if let attrs = try? FileManager.default.attributesOfItem(atPath: pathStr),
                  let mtimeNumber = attrs[.modificationDate] as? Date {
            resolvedMtime = Int(mtimeNumber.timeIntervalSince1970)
        } else {
            resolvedMtime = nil
        }

        let material = buildKeyMaterial(
            path: pathStr,
            mtime: resolvedMtime,
            ignoreExifRotation: ignoreExifRotation,
            extra: extra
        )
        return md5Hex(material)
    }

    static func diskFilename(cacheKey: String, size: Int) -> String {
        "\(cacheKey)_\(size).jpg"
    }
}
