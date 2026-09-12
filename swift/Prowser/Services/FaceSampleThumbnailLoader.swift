import AppKit
import CryptoKit
import Foundation

/// Loads 96×96 face sample thumbnails from Python `faces/face_sample_cache.py` storage.
enum FaceSampleThumbnailLoader {
    private static let thumbSize: CGFloat = 96

    static func thumbnail(
        imagePath: String,
        embedding: [Double],
        cacheDirectory: URL
    ) -> NSImage? {
        guard embedding.count == 128, let faceKey = embeddingFaceKey(embedding) else { return nil }
        let keys = [faceKey, "\(faceKey)_L"]
        for key in keys {
            if let image = loadByFaceKey(key, cacheDirectory: cacheDirectory) {
                return image
            }
            if !imagePath.isEmpty,
               let image = loadByPath(imagePath, faceKey: key, cacheDirectory: cacheDirectory) {
                return image
            }
        }
        return nil
    }

    static func embeddingFaceKey(_ embedding: [Double]) -> String? {
        guard embedding.count == 128 else { return nil }
        var data = Data(capacity: 128 * 8)
        for value in embedding {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        let digest = SHA256.hash(data: data)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func loadByFaceKey(_ faceKey: String, cacheDirectory: URL) -> NSImage? {
        let url = cacheDirectory
            .appendingPathComponent("face_cache/sample_thumbs/by_face_key", isDirectory: true)
            .appendingPathComponent("\(faceKey).png")
        return loadImage(at: url)
    }

    private static func loadByPath(_ imagePath: String, faceKey: String, cacheDirectory: URL) -> NSImage? {
        let resolvedPath = URL(fileURLWithPath: imagePath).standardizedFileURL.path
        let indexKey = "\(resolvedPath)::\(faceKey)"
        let indexURL = cacheDirectory
            .appendingPathComponent("face_cache/sample_thumbs/index.json")
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = index[indexKey] as? [String: Any] else {
            return nil
        }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedPath),
           let mtime = attributes[.modificationDate] as? Date,
           let size = attributes[.size] as? NSNumber {
            if let savedMtime = entry["mtime"] as? Double, abs(savedMtime - mtime.timeIntervalSince1970) > 0.001 {
                return nil
            }
            if let savedSize = entry["size"] as? Int, savedSize != size.intValue {
                return nil
            }
        }
        let thumbURL = cacheDirectory
            .appendingPathComponent("face_cache/sample_thumbs/images", isDirectory: true)
            .appendingPathComponent("\(pathHash(indexKey)).png")
        return loadImage(at: thumbURL)
    }

    private static func pathHash(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func loadImage(at url: URL) -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url),
              image.isValid else {
            return nil
        }
        if image.size.width == thumbSize && image.size.height == thumbSize {
            return image
        }
        let scaled = NSImage(size: NSSize(width: thumbSize, height: thumbSize))
        scaled.lockFocus()
        image.draw(
            in: NSRect(x: 0, y: 0, width: thumbSize, height: thumbSize),
            from: .zero,
            operation: .copy,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        scaled.unlockFocus()
        return scaled
    }
}
