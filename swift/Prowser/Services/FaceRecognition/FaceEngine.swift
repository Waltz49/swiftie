import CoreGraphics
import Accelerate
import Foundation
import ImageIO
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

    /// One ImageIO load for detection + assign dialog preview (avoids a second full-resolution decode).
    struct PathEncodeResult {
        var detections: [FaceDetection]
        var displayCGImage: CGImage
    }

    static func encodeFacesFromPath(_ imagePath: String, profile: ProfilePaths) -> [FaceDetection] {
        encodeFacesFromPathWithDisplayImage(imagePath, profile: profile)?.detections ?? []
    }

    static func encodeFacesFromPathWithDisplayImage(_ imagePath: String, profile: ProfilePaths) -> PathEncodeResult? {
        guard loadModelsIfNeeded(profile: profile),
              let pack = loadRGB(imagePath: imagePath) else { return nil }
        var detections = encodeFacesRGB(width: pack.detectWidth, height: pack.detectHeight, rgb: pack.rgb)
        if pack.fullWidth != pack.detectWidth || pack.fullHeight != pack.detectHeight {
            let sx = Double(pack.fullWidth) / Double(pack.detectWidth)
            let sy = Double(pack.fullHeight) / Double(pack.detectHeight)
            detections = detections.map { scaleDetection($0, sx: sx, sy: sy) }
        }
        return PathEncodeResult(detections: detections, displayCGImage: pack.displayCGImage)
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
        var displayCGImage: CGImage
        var rgb: Data
    }

    private static func loadRGB(imagePath: String) -> RGBPack? {
        guard let fullCG = ImageRecognitionImageLoader.loadCGImage(path: imagePath) else {
            return nil
        }
        let working = downscaledForFaceScanning(fullCG, maxLongEdge: scanningDownscaleThreshold)
        guard let rgb = rgbData(from: working) else { return nil }
        return RGBPack(
            fullWidth: fullCG.width,
            fullHeight: fullCG.height,
            detectWidth: working.width,
            detectHeight: working.height,
            displayCGImage: fullCG,
            rgb: rgb
        )
    }

    /// Same sizing as `faces/face_engine._maybe_resize_for_detection` (longest edge cap, int dimensions).
    private static func downscaledForFaceScanning(_ cg: CGImage, maxLongEdge: Int) -> CGImage {
        let width = cg.width
        let height = cg.height
        let longest = max(width, height)
        guard longest > maxLongEdge else { return cg }
        let scale = Double(maxLongEdge) / Double(longest)
        let newWidth = Int(Double(width) * scale)
        let newHeight = Int(Double(height) * scale)
        guard newWidth > 0, newHeight > 0 else { return cg }
        let colorSpace = cg.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return cg }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return ctx.makeImage() ?? cg
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
                space: cg.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        var rgb = Data(count: width * height * 3)
        rgba.withUnsafeBytes { src in
            rgb.withUnsafeMutableBytes { dst in
                guard let s = src.baseAddress, let d = dst.baseAddress else { return }
                var srcBuf = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: s),
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: bytesPerRow
                )
                var dstBuf = vImage_Buffer(
                    data: d,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width * 3
                )
                vImageConvert_RGBA8888toRGB888(&srcBuf, &dstBuf, vImage_Flags(kvImageNoFlags))
            }
        }
        return rgb
    }
}
