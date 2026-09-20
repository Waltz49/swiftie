import AppKit
import Foundation
import ProwserDlibBridge

/// Port of `faces/face_engine.py` using native dlib.
enum FaceEngine {
    static let scanningDownscaleThreshold = 2000
    static let defaultTolerance = 0.6

    struct FaceDetection: Sendable {
        var location: (top: Int, right: Int, bottom: Int, left: Int)
        var encoding: [Double]
    }

    static func isBridgeLinked() -> Bool {
        ProwserDlibBridge.isBridgeLinked
    }

    static func modelsInstalled(profile: ProfilePaths) -> Bool {
        FaceModelManifest.isInstalled(profile: profile)
    }

    static func isRuntimeReady(profile: ProfilePaths) -> Bool {
        isBridgeLinked() && modelsInstalled(profile: profile) && ProwserDlibBridge.modelsLoaded
    }

    @discardableResult
    static func loadModelsIfNeeded(profile: ProfilePaths) -> Bool {
        guard modelsInstalled(profile: profile) else { return false }
        if ProwserDlibBridge.modelsLoaded { return true }
        let dir = profile.dlibModelsDirectory
        let shape = dir.appendingPathComponent("shape_predictor_5_face_landmarks.dat").path
        let resnet = dir.appendingPathComponent("dlib_face_recognition_resnet_model_v1.dat").path
        return ProwserDlibBridge.loadModels(shapePredictorPath: shape, faceRecognitionResNetPath: resnet)
    }

    static func encodeFacesFromPath(_ imagePath: String, profile: ProfilePaths) -> [FaceDetection] {
        guard loadModelsIfNeeded(profile: profile),
              let pack = loadRGB(imagePath: imagePath) else { return [] }
        var detections = encodeFacesRGB(width: pack.detectWidth, height: pack.detectHeight, rgb: pack.rgb)
        if pack.fullWidth != pack.detectWidth || pack.fullHeight != pack.detectHeight {
            let sx = Double(pack.fullWidth) / Double(pack.detectWidth)
            let sy = Double(pack.fullHeight) / Double(pack.detectHeight)
            detections = detections.map { scaleDetection($0, sx: sx, sy: sy) }
        }
        return detections
    }

    private static func scaleDetection(_ det: FaceDetection, sx: Double, sy: Double) -> FaceDetection {
        FaceDetection(
            location: (
                Int(Double(det.location.top) * sy),
                Int(Double(det.location.right) * sx),
                Int(Double(det.location.bottom) * sy),
                Int(Double(det.location.left) * sx)
            ),
            encoding: det.encoding
        )
    }

    static func encodeFacesRGB(width: Int, height: Int, rgb: Data) -> [FaceDetection] {
        guard let raw = ProwserDlibBridge.encodeFacesRGB(width: width, height: height, rgb: rgb) else { return [] }
        return raw.map { det in
            FaceDetection(
                location: det.rect,
                encoding: det.encoding.map(Double.init)
            )
        }
    }

    static func compareFaces(knownEncodings: [[Double]], unknownEncoding: [Double], tolerance: Double = defaultTolerance) -> Bool {
        guard let minDist = faceDistance(knownEncodings: knownEncodings, unknownEncoding: unknownEncoding) else {
            return false
        }
        return minDist <= tolerance
    }

    static func faceDistance(knownEncodings: [[Double]], unknownEncoding: [Double]) -> Double? {
        let known = knownEncodings.map { $0.map(Float.init) }
        let unknown = unknownEncoding.map(Float.init)
        return ProwserDlibBridge.minFaceDistance(known: known, unknown: unknown)
    }

    static func faceMeanDistance(knownEncodings: [[Double]], unknownEncoding: [Double]) -> Double? {
        guard !knownEncodings.isEmpty, unknownEncoding.count == 128 else { return nil }
        var sum = 0.0
        for known in knownEncodings {
            guard known.count == 128, let d = faceDistance(knownEncodings: [known], unknownEncoding: unknownEncoding) else {
                return nil
            }
            sum += d
        }
        return sum / Double(knownEncodings.count)
    }

    private struct RGBPack {
        var fullWidth: Int
        var fullHeight: Int
        var detectWidth: Int
        var detectHeight: Int
        var rgb: Data
    }

    private static func loadRGB(imagePath: String) -> RGBPack? {
        guard let cg = ImageRecognitionImageLoader.loadCGImage(path: imagePath) else { return nil }
        let fullWidth = cg.width
        let fullHeight = cg.height
        var working = cg
        let maxDim = max(fullWidth, fullHeight)
        if maxDim > scanningDownscaleThreshold {
            let scale = Double(scanningDownscaleThreshold) / Double(maxDim)
            let newW = Int(Double(fullWidth) * scale)
            let newH = Int(Double(fullHeight) * scale)
            if let scaled = resize(cg: cg, width: newW, height: newH) {
                working = scaled
            }
        }
        guard let rgb = rgbData(from: working) else { return nil }
        return RGBPack(
            fullWidth: fullWidth,
            fullHeight: fullHeight,
            detectWidth: working.width,
            detectHeight: working.height,
            rgb: rgb
        )
    }

    /// Bitmap contexts use a bottom-left origin; flip so row 0 is the image top (matches dlib + overlay).
    private static func drawCGImageTopLeftIntoContext(_ cg: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(cg, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()
    }

    private static func resize(cg: CGImage, width: Int, height: Int) -> CGImage? {
        guard let colorSpace = cg.colorSpace else { return nil }
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        drawCGImageTopLeftIntoContext(cg, in: CGRect(x: 0, y: 0, width: width, height: height), context: ctx)
        return ctx.makeImage()
    }

    private static func rgbData(from cg: CGImage) -> Data? {
        let width = cg.width
        let height = cg.height
        let bytesPerRow = width * 4
        var rgba = Data(count: height * bytesPerRow)
        let ok = rgba.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return false }
            guard let ctx = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            drawCGImageTopLeftIntoContext(cg, in: CGRect(x: 0, y: 0, width: width, height: height), context: ctx)
            return true
        }
        guard ok else { return nil }
        var rgb = Data(count: width * height * 3)
        rgb.withUnsafeMutableBytes { dst in
            rgba.withUnsafeBytes { src in
                guard let d = dst.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let s = src.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                var di = 0
                for y in 0..<height {
                    for x in 0..<width {
                        let si = y * bytesPerRow + x * 4
                        d[di] = s[si]
                        d[di + 1] = s[si + 1]
                        d[di + 2] = s[si + 2]
                        di += 3
                    }
                }
            }
        }
        return rgb
    }
}
