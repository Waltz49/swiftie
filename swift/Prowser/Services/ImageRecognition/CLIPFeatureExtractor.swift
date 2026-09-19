import CoreML
import Foundation

enum CLIPFeatureExtractorError: Error, LocalizedError {
    case modelNotInstalled
    case inferenceFailed
    case tokenizerMissing

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled: return "CLIP model is not installed."
        case .inferenceFailed: return "CLIP inference failed."
        case .tokenizerMissing: return "CLIP tokenizer files are missing from the text model package."
        }
    }
}

final class CLIPFeatureExtractor: @unchecked Sendable {
    private let imageModelID: String
    private let textModelID: String
    private let profile: ProfilePaths
    private var imageModel: MLModel?
    private var textModel: MLModel?
    private var tokenizer: CLIPTokenizer?
    private let lock = NSLock()

    init(clipModelName: String, profile: ProfilePaths) {
        let ids = ModelManifest.clipBundleIDs(for: clipModelName)
        imageModelID = ids[0]
        textModelID = ids[1]
        self.profile = profile
    }

    func extractImageFeatures(
        paths: [String],
        progress: @escaping (Int, Int, String) -> Void,
        shouldCancel: @escaping () -> Bool
    ) throws -> [String: [Float]] {
        let model = try loadImageModel()
        var result: [String: [Float]] = [:]
        let total = paths.count
        for (index, path) in paths.enumerated() {
            if shouldCancel() { break }
            let name = (path as NSString).lastPathComponent
            progress(index, total, "CLIP image \(name)... (\(index + 1)/\(total))")
            guard let input = CLIPPreprocessor.makeImageInput(from: path),
                  let vector = try runImage(model: model, input: input) else { continue }
            result[path] = normalize(vector)
        }
        progress(total, total, "")
        return result
    }

    func extractTextFeature(prompt: String) throws -> [Float] {
        let model = try loadTextModel()
        let tok = try loadTokenizer()
        let ids = tok.encode(text: prompt)
        guard let vector = try runText(model: model, tokenIDs: ids) else {
            throw CLIPFeatureExtractorError.inferenceFailed
        }
        return normalize(vector)
    }

    private func normalize(_ v: [Float]) -> [Float] {
        var sum: Float = 0
        for x in v { sum += x * x }
        let norm = sqrt(sum)
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    private func loadImageModel() throws -> MLModel {
        lock.lock()
        if let imageModel {
            lock.unlock()
            return imageModel
        }
        lock.unlock()
        let model = try loadModelFromDisk(id: imageModelID)
        lock.lock()
        imageModel = model
        lock.unlock()
        return model
    }

    private func loadTextModel() throws -> MLModel {
        lock.lock()
        if let textModel {
            lock.unlock()
            return textModel
        }
        lock.unlock()
        let model = try loadModelFromDisk(id: textModelID)
        lock.lock()
        textModel = model
        lock.unlock()
        return model
    }

    private func loadTokenizer() throws -> CLIPTokenizer {
        lock.lock()
        if let tokenizer {
            lock.unlock()
            return tokenizer
        }
        lock.unlock()
        let dir = ImageRecognitionPaths.modelInstallDirectory(profile: profile, modelID: textModelID)
        guard let tok = CLIPTokenizer(modelInstallDirectory: dir) else {
            throw CLIPFeatureExtractorError.tokenizerMissing
        }
        lock.lock()
        tokenizer = tok
        lock.unlock()
        return tok
    }

    private func loadModelFromDisk(id: String) throws -> MLModel {
        guard let entry = ModelManifest.entry(id: id),
              ImageRecognitionPaths.isModelInstalled(profile: profile, entry: entry) else {
            throw CLIPFeatureExtractorError.modelNotInstalled
        }
        let url = ImageRecognitionPaths.artifactURL(
            profile: profile,
            modelID: id,
            fileName: entry.artifacts[0].fileName
        )
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let loadURL = try CoreMLModelCompilation.ensureCompiled(at: url)
        return try MLModel(contentsOf: loadURL, configuration: config)
    }

    private func runImage(model: MLModel, input: [Float]) throws -> [Float]? {
        let side = 224
        let shape: [NSNumber] = [1, 3, side as NSNumber, side as NSNumber]
        guard let array = try? MLMultiArray(shape: shape, dataType: .float32) else { return nil }
        for i in 0 ..< input.count { array[i] = NSNumber(value: input[i]) }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["input": array])
        let out = try model.prediction(from: provider)
        return firstVector(in: out)
    }

    private func runText(model: MLModel, tokenIDs: [Int]) throws -> [Float]? {
        let shape: [NSNumber] = [1, tokenIDs.count as NSNumber]
        guard let array = try? MLMultiArray(shape: shape, dataType: .int32) else { return nil }
        for i in 0 ..< tokenIDs.count { array[i] = NSNumber(value: tokenIDs[i]) }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["input": array])
        let out = try model.prediction(from: provider)
        return firstVector(in: out)
    }

    private func firstVector(in out: MLFeatureProvider) -> [Float]? {
        for name in out.featureNames {
            if let feat = out.featureValue(for: name)?.multiArrayValue {
                return multiArrayToFloat(feat)
            }
        }
        return nil
    }

    private func multiArrayToFloat(_ array: MLMultiArray) -> [Float] {
        let count = array.count
        var out = [Float](repeating: 0, count: count)
        switch array.dataType {
        case .float32:
            let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: count)
            for i in 0 ..< count { out[i] = ptr[i] }
        case .double:
            let ptr = array.dataPointer.bindMemory(to: Double.self, capacity: count)
            for i in 0 ..< count { out[i] = Float(ptr[i]) }
        default:
            for i in 0 ..< count { out[i] = array[i].floatValue }
        }
        return out
    }
}
