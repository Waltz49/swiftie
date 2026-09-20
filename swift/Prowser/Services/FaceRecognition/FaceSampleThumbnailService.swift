import AppKit
import CoreGraphics
import Foundation

/// 96×96 face sample thumbs for Settings → Face Recognition (port of `faces/face_sample_thumbnail.py`).
enum FaceSampleThumbnailService {
    static let thumbSize: CGFloat = 96

    static func thumbnail(
        profile: ProfilePaths,
        imagePath: String,
        embedding: [Double]
    ) -> NSImage? {
        let faceKey = FaceSampleCache.embeddingToFaceKey(embedding)
        if !imagePath.isEmpty, let url = FaceSampleCache.cachedPNGPath(profile: profile, imagePath: imagePath, faceKey: faceKey),
           let img = NSImage(contentsOf: url) {
            return img
        }
        if let faceKey, let url = FaceSampleCache.cachedPNGByFaceKey(profile: profile, faceKey: faceKey),
           let img = NSImage(contentsOf: url) {
            return img
        }
        guard let built = buildThumbnail(imagePath: imagePath, embedding: embedding, profile: profile) else {
            return nil
        }
        if let tiff = built.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            FaceSampleCache.writePNG(profile: profile, imagePath: imagePath, faceKey: faceKey, pngData: png)
        }
        return built
    }

    private static func buildThumbnail(
        imagePath: String,
        embedding: [Double],
        profile: ProfilePaths
    ) -> NSImage? {
        guard !imagePath.isEmpty,
              FileManager.default.fileExists(atPath: imagePath),
              let cg = ImageRecognitionImageLoader.loadCGImage(path: imagePath) else {
            return nil
        }
        let matched = matchedFaceLocation(imagePath: imagePath, embedding: embedding, profile: profile)
        if let loc = matched {
            if let crop = cropFace(cgImage: cg, location: loc) {
                return scaleToSquare(crop)
            }
        }
        return scaleToSquare(cg)
    }

    private static func matchedFaceLocation(
        imagePath: String,
        embedding: [Double],
        profile: ProfilePaths
    ) -> (top: Int, right: Int, bottom: Int, left: Int)? {
        let detections = FaceEngine.encodeFacesFromPath(imagePath, profile: profile)
        if detections.count == 1 {
            return detections[0].location
        }
        var best: (top: Int, right: Int, bottom: Int, left: Int)?
        var bestDist: Double?
        for det in detections {
            guard let d = FaceEngine.faceDistance(knownEncodings: [det.encoding], unknownEncoding: embedding) else {
                continue
            }
            if bestDist == nil || d < bestDist! {
                bestDist = d
                best = det.location
            }
        }
        if let best, let bestDist, bestDist <= FaceEngine.defaultTolerance {
            return best
        }
        return nil
    }

    private static func cropFace(
        cgImage: CGImage,
        location: (top: Int, right: Int, bottom: Int, left: Int),
        pad: Int = 10
    ) -> CGImage? {
        let w = cgImage.width
        let h = cgImage.height
        let leftP = max(0, location.left - pad)
        let topP = max(0, location.top - pad)
        let rightP = min(w, location.right + pad)
        let bottomP = min(h, location.bottom + pad)
        let cw = rightP - leftP
        let ch = bottomP - topP
        guard cw > 0, ch > 0 else { return nil }
        return cgImage.cropping(to: CGRect(x: leftP, y: topP, width: cw, height: ch))
    }

    private static func scaleToSquare(_ cgImage: CGImage) -> NSImage? {
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        guard w > 0, h > 0 else { return nil }
        let scale = max(thumbSize / w, thumbSize / h)
        let dw = w * scale
        let dh = h * scale
        let out = NSImage(size: NSSize(width: thumbSize, height: thumbSize))
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let dx = (thumbSize - dw) / 2
        let dy = (thumbSize - dh) / 2
        NSGraphicsContext.current?.cgContext.draw(cgImage, in: CGRect(x: dx, y: dy, width: dw, height: dh))
        out.unlockFocus()
        return out
    }
}
