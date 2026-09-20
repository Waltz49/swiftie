import Foundation
import ProwserDlibBridgeCore

/// Swift wrapper around the C dlib bridge.
public enum ProwserDlibBridge {
    public static let encodingDimension = Int(PROWSER_DLIB_ENCODING_DIM)

    public static var isBridgeLinked: Bool {
        prowser_dlib_bridge_linked()
    }

    public static var modelsLoaded: Bool {
        prowser_dlib_models_are_loaded()
    }

    public static func loadModels(shapePredictorPath: String, faceRecognitionResNetPath: String) -> Bool {
        shapePredictorPath.withCString { shapePtr in
            faceRecognitionResNetPath.withCString { resnetPtr in
                prowser_dlib_load_models(shapePtr, resnetPtr)
            }
        }
    }

    public static func unloadModels() {
        prowser_dlib_unload_models()
    }

    public struct FaceDetection: Sendable {
        public var rect: (top: Int, right: Int, bottom: Int, left: Int)
        public var encoding: [Float]
    }

    public static func encodeFacesRGB(width: Int, height: Int, rgb: Data) -> [FaceDetection]? {
        guard width > 0, height > 0, rgb.count >= width * height * 3 else { return nil }
        let maxFaces = Int(PROWSER_DLIB_MAX_FACES)
        let dim = Int(PROWSER_DLIB_ENCODING_DIM)
        var encodings = [Float](repeating: 0, count: maxFaces * dim)
        var rects = [ProwserFaceRect](
            repeating: ProwserFaceRect(top: 0, right: 0, bottom: 0, left: 0),
            count: maxFaces
        )
        let count: Int = rgb.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
            return Int(
                prowser_dlib_encode_faces_rgb(
                    base,
                    Int32(width),
                    Int32(height),
                    Int32(width * 3),
                    &encodings,
                    &rects,
                    Int32(maxFaces)
                )
            )
        }
        guard count >= 0 else { return nil }
        var results: [FaceDetection] = []
        for i in 0..<count {
            let r = rects[i]
            let start = i * encodingDimension
            let end = start + encodingDimension
            results.append(
                FaceDetection(
                    rect: (Int(r.top), Int(r.right), Int(r.bottom), Int(r.left)),
                    encoding: Array(encodings[start..<end])
                )
            )
        }
        return results
    }

    public static func minFaceDistance(known: [[Float]], unknown: [Float]) -> Double? {
        guard !known.isEmpty, unknown.count == encodingDimension else { return nil }
        var flat = [Float]()
        for enc in known {
            guard enc.count == encodingDimension else { return nil }
            flat.append(contentsOf: enc)
        }
        return unknown.withUnsafeBufferPointer { unknownPtr in
            flat.withUnsafeBufferPointer { knownPtr in
                let d = prowser_dlib_min_face_distance(
                    knownPtr.baseAddress,
                    Int32(known.count),
                    unknownPtr.baseAddress
                )
                return d >= 0 ? d : nil
            }
        }
    }
}
