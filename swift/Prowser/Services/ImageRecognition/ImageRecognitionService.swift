import Foundation

/// Shared CNN/CLIP feature extraction with disk cache.
@MainActor
final class ImageRecognitionService {
    private let profile: ProfilePaths
    private var cacheManager: FeatureCacheManager?

    init(profile: ProfilePaths) {
        self.profile = profile
    }

    func rebind(config: AppConfig) {
        let resnet = config.string(forKey: "resnet_model", default: "resnet18")
        let clip = config.string(forKey: "clip_model_name", default: "openai/clip-vit-base-patch32")
        cacheManager = FeatureCacheManager(
            cacheRoot: profile.imageRecognitionCacheDirectory,
            resnetModel: resnet,
            clipModelName: clip
        )
    }

    func flushCaches() {
        cacheManager?.flushCaches()
    }

    /// Vision feature prints (⌘K fallback when ResNet Core ML is not installed).
    func visionFeatures(
        for paths: [String],
        progress: @escaping (Int, Int, String) -> Void,
        shouldCancel: @escaping () -> Bool
    ) async throws -> [String: [Float]] {
        guard let cacheManager else { throw VisionFeaturePrintExtractor.ExtractorError.noFeaturePrint }
        let pathsCopy = paths
        let cacheLookup = await Task.detached {
            var result: [String: [Float]] = [:]
            var needExtract: [String] = []
            for path in pathsCopy {
                guard let attrs = ImageRecognitionService.fileAttributes(for: path) else { continue }
                if let cached = cacheManager.getVision(path: path, mtime: attrs.mtime, size: attrs.size) {
                    result[path] = cached
                } else {
                    needExtract.append(path)
                }
            }
            return (result, needExtract)
        }.value
        var result = cacheLookup.0
        let needExtract = cacheLookup.1

        let cachedCount = result.count
        if cachedCount > 0, needExtract.isEmpty {
            progress(cachedCount, cachedCount, "Using cached features (\(cachedCount) images)")
            return result
        }

        if !needExtract.isEmpty {
            let pending = needExtract
            let extracted = try await Task.detached {
                var out: [String: [Float]] = [:]
                let total = pending.count
                for (index, path) in pending.enumerated() {
                    if shouldCancel() { break }
                    let name = (path as NSString).lastPathComponent
                    await MainActor.run {
                        progress(
                            index,
                            total,
                            "Analyzing \(name)... (\(index + 1)/\(total), \(cachedCount) cached)"
                        )
                    }
                    if let vector = try? VisionFeaturePrintExtractor.featureVector(path: path) {
                        out[path] = vector
                    }
                }
                await MainActor.run { progress(total, total, "") }
                return out
            }.value
            for (path, feat) in extracted {
                if let attrs = fileAttributes(path: path) {
                    cacheManager.setVision(path: path, mtime: attrs.mtime, size: attrs.size, feature: feat)
                }
                result[path] = feat
            }
            cacheManager.flushCaches()
        }
        return result
    }

    func cnnFeatures(
        for paths: [String],
        config: AppConfig,
        progress: @escaping (Int, Int, String) -> Void,
        shouldCancel: @escaping () -> Bool
    ) async throws -> [String: [Float]] {
        let resnet = config.string(forKey: "resnet_model", default: "resnet18")
        let modelIDs = ModelManifest.resnetBundleIDs(for: resnet)
        try await ModelDownloadService.ensureModelsInstalled(
            profile: profile,
            modelIDs: modelIDs,
            purpose: "Download is required for Search for Similar Images (⌘K) and background indexing."
        )
        guard let cacheManager else { throw ResNetFeatureExtractorError.inferenceFailed }
        let batch = min(32, max(8, config.int(forKey: "cnn_feature_batch_size", default: 16)))
        let extractor = ResNetFeatureExtractor(resnetModel: resnet, profile: profile)

        var needExtract: [String] = []
        var result: [String: [Float]] = [:]
        for path in paths {
            guard let attrs = fileAttributes(path: path) else { continue }
            if let cached = cacheManager.getCNN(path: path, mtime: attrs.mtime, size: attrs.size) {
                result[path] = cached
            } else {
                needExtract.append(path)
            }
        }

        let cachedCount = result.count
        if cachedCount > 0, needExtract.isEmpty {
            progress(cachedCount, cachedCount, "Using cached features (\(cachedCount) images)")
            return result
        }

        if !needExtract.isEmpty {
            let pending = needExtract
            let extracted = try await Task.detached {
                try extractor.extractFeatures(
                    paths: pending,
                    batchSize: batch,
                    progress: { cur, max, label in
                        progress(
                            cur,
                            max,
                            max > 0 ? "\(label) (\(cachedCount) cached)" : label
                        )
                    },
                    shouldCancel: shouldCancel
                )
            }.value
            for (path, feat) in extracted {
                if let attrs = fileAttributes(path: path) {
                    cacheManager.setCNN(path: path, mtime: attrs.mtime, size: attrs.size, feature: feat)
                }
                result[path] = feat
            }
            cacheManager.flushCaches()
        }
        return result
    }

    func clipImageFeatures(
        for paths: [String],
        config: AppConfig,
        progress: @escaping (Int, Int, String) -> Void,
        shouldCancel: @escaping () -> Bool
    ) async throws -> [String: [Float]] {
        let clipName = config.string(forKey: "clip_model_name", default: "openai/clip-vit-base-patch32")
        let modelIDs = ModelManifest.clipBundleIDs(for: clipName)
        try await ModelDownloadService.ensureModelsInstalled(
            profile: profile,
            modelIDs: modelIDs,
            purpose: "Download is required for Search by Text (⌘F) and background indexing."
        )
        guard let cacheManager else { throw CLIPFeatureExtractorError.inferenceFailed }
        let extractor = CLIPFeatureExtractor(clipModelName: clipName, profile: profile)

        var needExtract: [String] = []
        var result: [String: [Float]] = [:]
        for path in paths {
            guard let attrs = fileAttributes(path: path) else { continue }
            if let cached = cacheManager.getCLIP(path: path, mtime: attrs.mtime, size: attrs.size) {
                result[path] = cached
            } else {
                needExtract.append(path)
            }
        }

        if !needExtract.isEmpty {
            let pending = needExtract
            let extracted = try await Task.detached {
                try extractor.extractImageFeatures(
                    paths: pending,
                    progress: progress,
                    shouldCancel: shouldCancel
                )
            }.value
            for (path, feat) in extracted {
                if let attrs = fileAttributes(path: path) {
                    cacheManager.setCLIP(path: path, mtime: attrs.mtime, size: attrs.size, feature: feat)
                }
                result[path] = feat
            }
            cacheManager.flushCaches()
        }
        return result
    }

    func clipTextFeature(prompt: String, config: AppConfig) async throws -> [Float] {
        let clipName = config.string(forKey: "clip_model_name", default: "openai/clip-vit-base-patch32")
        let modelIDs = ModelManifest.clipBundleIDs(for: clipName)
        try await ModelDownloadService.ensureModelsInstalled(
            profile: profile,
            modelIDs: modelIDs,
            purpose: "Download is required to encode text for Search by Text (⌘F)."
        )
        let extractor = CLIPFeatureExtractor(clipModelName: clipName, profile: profile)
        return try await Task.detached {
            try extractor.extractTextFeature(prompt: prompt)
        }.value
    }

    private func fileAttributes(path: String) -> (mtime: Double, size: Int)? {
        Self.fileAttributes(for: path)
    }

    nonisolated static func fileAttributes(for path: String) -> (mtime: Double, size: Int)? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let date = values.contentModificationDate,
              let size = values.fileSize else { return nil }
        return (date.timeIntervalSince1970, size)
    }
}
