import CoreML
import Foundation

enum ResNetFeatureExtractorError: Error, LocalizedError {
    case modelNotInstalled
    case inferenceFailed

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled: return "ResNet model is not installed. Download it from the search prompt or Settings."
        case .inferenceFailed: return "Could not extract image features."
        }
    }
}

/// Runs installed Core ML ResNet feature models.
final class ResNetFeatureExtractor: @unchecked Sendable {
    private let modelID: String
    private let profile: ProfilePaths
    private var loadedModel: MLModel?
    private let lock = NSLock()

    init(resnetModel: String, profile: ProfilePaths) {
        let ids = ModelManifest.resnetBundleIDs(for: resnetModel)
        self.modelID = ids[0]
        self.profile = profile
    }

    func extractFeatures(paths: [String], batchSize: Int, progress: @escaping (Int, Int, String) -> Void, shouldCancel: @escaping () -> Bool) throws -> [String: [Float]] {
        let model = try loadModel()
        var result: [String: [Float]] = [:]
        let total = paths.count
        var index = 0
        while index < paths.count {
            if shouldCancel() { break }
            let path = paths[index]
            let name = (path as NSString).lastPathComponent
            progress(index, total, "Analyzing \(name)... (\(index + 1)/\(total))")
            if let input = ImageNetPreprocessor.makeInputMultiArray(from: path),
               let vector = try run(model: model, input: input) {
                result[path] = vector
            }
            index += 1
        }
        progress(total, total, "")
        return result
    }

    func extractFeature(path: String) throws -> [Float] {
        let model = try loadModel()
        guard let input = ImageNetPreprocessor.makeInputMultiArray(from: path) else {
            throw ResNetFeatureExtractorError.inferenceFailed
        }
        guard let vector = try run(model: model, input: input) else {
            throw ResNetFeatureExtractorError.inferenceFailed
        }
        return vector
    }

    private func loadModel() throws -> MLModel {
        lock.lock()
        if let loadedModel {
            lock.unlock()
            return loadedModel
        }
        lock.unlock()
        guard let entry = ModelManifest.entry(id: modelID) else {
            throw ResNetFeatureExtractorError.modelNotInstalled
        }
        guard ImageRecognitionPaths.isModelInstalled(profile: profile, entry: entry) else {
            throw ResNetFeatureExtractorError.modelNotInstalled
        }
        let artifactName = entry.artifacts[0].fileName
        let url = ImageRecognitionPaths.artifactURL(profile: profile, modelID: modelID, fileName: artifactName)
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let loadURL = try CoreMLModelCompilation.ensureCompiled(at: url)
        let model = try MLModel(contentsOf: loadURL, configuration: config)
        lock.lock()
        loadedModel = model
        lock.unlock()
        return model
    }

    private func run(model: MLModel, input: [Float]) throws -> [Float]? {
        let side = 224
        let shape: [NSNumber] = [1, 3, side as NSNumber, side as NSNumber]
        guard let array = try? MLMultiArray(shape: shape, dataType: .float32) else { return nil }
        for i in 0 ..< input.count {
            array[i] = NSNumber(value: input[i])
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["input": array])
        let out = try model.prediction(from: provider)
        for name in out.featureNames {
            if let feat = out.featureValue(for: name)?.multiArrayValue {
                return multiArrayToFloat(feat)
            }
        }
        if let feat = out.featureValue(for: "features")?.multiArrayValue {
            return multiArrayToFloat(feat)
        }
        return nil
    }

    private func multiArrayToFloat(_ array: MLMultiArray) -> [Float] {
        let count = array.count
        var out = [Float](repeating: 0, count: count)
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: count)
        for i in 0 ..< count {
            out[i] = ptr[i]
        }
        return out
    }
}
