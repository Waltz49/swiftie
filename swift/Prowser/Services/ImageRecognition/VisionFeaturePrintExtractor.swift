import CoreGraphics
import Foundation
import ImageIO
import Vision

/// On-device similarity when Core ML ResNet packages are not installed (macOS Vision framework).
enum VisionFeaturePrintExtractor: Sendable {
    enum ExtractorError: Error, LocalizedError {
        case noFeaturePrint
        case imageLoadFailed

        var errorDescription: String? {
            switch self {
            case .noFeaturePrint: return "Could not compute image feature print."
            case .imageLoadFailed: return "Could not load image for similarity search."
            }
        }
    }

    /// Serializable embedding for disk cache (Vision feature print bytes as floats).
    static func featureVector(path: String) throws -> [Float] {
        let observation = try featurePrint(path: path)
        return vector(from: observation)
    }

    static func vector(from observation: VNFeaturePrintObservation) -> [Float] {
        let count = observation.elementCount
        return observation.data.withUnsafeBytes { raw in
            let bound = raw.bindMemory(to: Float.self)
            return Array(bound.prefix(count))
        }
    }

    private static func featurePrint(path: String) throws -> VNFeaturePrintObservation {
        guard let cgImage = loadCGImage(path: path) else { throw ExtractorError.imageLoadFailed }
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            throw ExtractorError.noFeaturePrint
        }
        return observation
    }

    private static func loadCGImage(path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
