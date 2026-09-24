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
        guard loadModelsIfNeeded(profile: profile),
              let pack = loadDetectionRGBPack(imagePath: imagePath) else { return [] }
        var detections = encodeFacesRGB(width: pack.detectWidth, height: pack.detectHeight, rgb: pack.rgb)
        if pack.scaleX != 1.0 || pack.scaleY != 1.0 {
            detections = detections.map { scaleDetection($0, sx: pack.scaleX, sy: pack.scaleY) }
        }
        return detections
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
        meanFaceDistance(knownEncodings: knownEncodings, unknownEncoding: unknownEncoding)
    }

    /// Average L2 distance to each known sample (port of `face_mean_distance`).
    static func meanFaceDistance(knownEncodings: [[Double]], unknownEncoding: [Double]) -> Double? {
        guard !knownEncodings.isEmpty, unknownEncoding.count == 128 else { return nil }
        let unknown = unknownEncoding.map(Float.init)
        var sum = 0.0
        for known in knownEncodings {
            guard known.count == 128 else { return nil }
            let knownF = known.map(Float.init)
            guard let d = ProwserDlibBridge.minFaceDistance(known: [knownF], unknown: unknown) else { return nil }
            sum += d
        }
        return sum / Double(knownEncodings.count)
    }

    /// Match phase helper: pre-convert known samples once per search.
    static func meanFaceDistance(knownEncodings: [[Float]], unknownEncoding: [Float]) -> Double? {
        guard !knownEncodings.isEmpty, unknownEncoding.count == 128 else { return nil }
        var sum = 0.0
        for known in knownEncodings {
            guard known.count == 128 else { return nil }
            guard let d = ProwserDlibBridge.minFaceDistance(known: [known], unknown: unknownEncoding) else { return nil }
            sum += d
        }
        return sum / Double(knownEncodings.count)
    }

    static func compareFaces(knownEncodings: [[Float]], unknownEncoding: [Float], tolerance: Float = Float(defaultTolerance)) -> Bool {
        guard let minDist = ProwserDlibBridge.minFaceDistance(known: knownEncodings, unknown: unknownEncoding) else {
            return false
        }
        return minDist <= Double(tolerance)
    }

    private struct RGBPack {
        var fullWidth: Int
        var fullHeight: Int
        var detectWidth: Int
        var detectHeight: Int
        var displayCGImage: CGImage
        var rgb: Data
    }

    private struct DetectionRGBPack {
        var detectWidth: Int
        var detectHeight: Int
        var scaleX: Double
        var scaleY: Double
        var rgb: Data
    }

    /// Scan/cache path: one ImageIO decode capped at `scanningDownscaleThreshold` (no full-resolution load).
    private static func loadDetectionRGBPack(imagePath: String) -> DetectionRGBPack? {
        guard let oriented = ImageRecognitionImageLoader.orientedPixelSize(path: imagePath) else { return nil }
        let fullWidth = oriented.width
        let fullHeight = oriented.height
        let longest = max(fullWidth, fullHeight)
        let detectCap = min(longest, scanningDownscaleThreshold)
        guard let working = ImageRecognitionImageLoader.loadCGImage(path: imagePath, maxPixelSize: detectCap) else {
            return nil
        }
        guard let rgb = rgbData(from: working) else { return nil }
        let scaleX = Double(fullWidth) / Double(working.width)
        let scaleY = Double(fullHeight) / Double(working.height)
        return DetectionRGBPack(
            detectWidth: working.width,
            detectHeight: working.height,
            scaleX: scaleX,
            scaleY: scaleY,
            rgb: rgb
        )
    }

    private static func loadRGB(imagePath: String) -> RGBPack? {
        guard let oriented = ImageRecognitionImageLoader.orientedPixelSize(path: imagePath) else { return nil }
        guard let fullCG = ImageRecognitionImageLoader.loadCGImage(path: imagePath) else {
            return nil
        }
        let fullWidth = oriented.width
        let fullHeight = oriented.height
        let longest = max(fullWidth, fullHeight)
        let detectCap = min(longest, scanningDownscaleThreshold)
        let working: CGImage
        if longest > scanningDownscaleThreshold,
           let downscaled = ImageRecognitionImageLoader.loadCGImage(path: imagePath, maxPixelSize: detectCap) {
            working = downscaled
        } else {
            working = fullCG
        }
        guard let rgb = rgbData(from: working) else { return nil }
        return RGBPack(
            fullWidth: fullWidth,
            fullHeight: fullHeight,
            detectWidth: working.width,
            detectHeight: working.height,
            displayCGImage: fullCG,
            rgb: rgb
        )
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
