import Foundation

/// Shared CNN/CLIP feature extraction with disk cache.
@MainActor
final class ImageRecognitionService {
    private let profile: ProfilePaths
    private var cacheManager: FeatureCacheManager?
    private var boundCacheRoot: URL?
    private var boundResnetModel: String?
    private var boundClipModel: String?
    private var clipExtractor: CLIPFeatureExtractor?
    private var resnetExtractor: ResNetFeatureExtractor?

    init(profile: ProfilePaths) {
        self.profile = profile
    }

    /// Rebinds extractors and feature cache to current settings. Returns true when cache binding or model keys changed.
    @discardableResult
    func rebind(config: AppConfig) -> Bool {
        let resnet = config.string(forKey: "resnet_model", default: "resnet18")
        let clip = config.string(forKey: "clip_model_name", default: "openai/clip-vit-base-patch32")
        let cacheRoot = profile.imageRecognitionCacheDirectory
        var modelKeysChanged = false
        if resnet != boundResnetModel {
            boundResnetModel = resnet
            resnetExtractor = nil
            modelKeysChanged = true
        }
        if clip != boundClipModel {
            boundClipModel = clip
            clipExtractor = nil
            modelKeysChanged = true
        }
        let cacheBindingChanged = modelKeysChanged
            || boundCacheRoot != cacheRoot
            || cacheManager == nil
        if cacheBindingChanged {
            boundCacheRoot = cacheRoot
            cacheManager = FeatureCacheManager(
                cacheRoot: cacheRoot,
                resnetModel: resnet,
                clipModelName: clip
            )
        }
        return cacheBindingChanged
    }

    /// Drop in-memory feature indexes after disk cache was cleared (settings); keeps model extractors.
    func discardInMemoryFeatureCaches(config: AppConfig) {
        let resnet = config.string(forKey: "resnet_model", default: "resnet18")
        let clip = config.string(forKey: "clip_model_name", default: "openai/clip-vit-base-patch32")
        let cacheRoot = profile.imageRecognitionCacheDirectory
        boundCacheRoot = cacheRoot
        cacheManager = FeatureCacheManager(
            cacheRoot: cacheRoot,
            resnetModel: resnet,
            clipModelName: clip
        )
    }

    private func clipExtractor(for clipName: String) -> CLIPFeatureExtractor {
        if let clipExtractor, boundClipModel == clipName {
            return clipExtractor
        }
        let created = CLIPFeatureExtractor(clipModelName: clipName, profile: profile)
        boundClipModel = clipName
        clipExtractor = created
        return created
    }

    private func resnetExtractor(for resnetModel: String) -> ResNetFeatureExtractor {
        if let resnetExtractor, boundResnetModel == resnetModel {
            return resnetExtractor
        }
        let created = ResNetFeatureExtractor(resnetModel: resnetModel, profile: profile)
        boundResnetModel = resnetModel
        resnetExtractor = created
        return created
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
        if !paths.isEmpty {
            progress(0, paths.count, Self.checkingCachedFeaturesLabel(fileCount: paths.count))
        }
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
            let extracted = await Task.detached {
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

    func pathNeedsCNN(path: String, config: AppConfig) -> Bool {
        guard let cacheManager else { return true }
        guard let attrs = fileAttributes(path: path) else { return false }
        return cacheManager.getCNN(path: path, mtime: attrs.mtime, size: attrs.size) == nil
    }

    func pathNeedsCLIP(path: String, config: AppConfig) -> Bool {
        guard let cacheManager else { return true }
        let expectedDim = ModelManifest.clipFeatureDimension(
            for: config.string(forKey: "clip_model_name", default: "openai/clip-vit-base-patch32")
        )
        guard let attrs = fileAttributes(path: path) else { return false }
        if let cached = cacheManager.getCLIP(path: path, mtime: attrs.mtime, size: attrs.size),
           cached.count == expectedDim {
            return false
        }
        return true
    }

    func pathsNeedingCNN(paths: [String], config: AppConfig) -> [String] {
        paths.filter { pathNeedsCNN(path: $0, config: config) }
    }

    func pathsNeedingCLIP(paths: [String], config: AppConfig) -> [String] {
        paths.filter { pathNeedsCLIP(path: $0, config: config) }
    }

    func cnnFeatures(
        for paths: [String],
        config: AppConfig,
        progress: @escaping (Int, Int, String) -> Void,
        shouldCancel: @escaping () -> Bool,
        allowDownloadPrompt: Bool = true
    ) async throws -> [String: [Float]] {
        let resnet = config.string(forKey: "resnet_model", default: "resnet18")
        let modelIDs = ModelManifest.resnetBundleIDs(for: resnet)
        try await ModelDownloadService.ensureModelsInstalled(
            profile: profile,
            config: config,
            modelIDs: modelIDs,
            purpose: "Download is required for Search for Similar Images (⌘K) and background indexing.",
            allowDownloadPrompt: allowDownloadPrompt
        )
        guard let cacheManager else { throw ResNetFeatureExtractorError.inferenceFailed }
        let batch = min(32, max(8, config.int(forKey: "cnn_feature_batch_size", default: 16)))
        let extractor = resnetExtractor(for: resnet)

        if !paths.isEmpty {
            progress(0, paths.count, Self.checkingCachedFeaturesLabel(fileCount: paths.count))
        }
        let pathsCopy = paths
        let cacheLookup = await Task.detached {
            Self.partitionCNNCache(paths: pathsCopy, cacheManager: cacheManager, resnetModel: resnet)
        }.value
        var result = cacheLookup.cached
        let needExtract = cacheLookup.needExtract

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
        shouldCancel: @escaping () -> Bool,
        allowDownloadPrompt: Bool = true
    ) async throws -> [String: [Float]] {
        let clipName = config.string(forKey: "clip_model_name", default: "openai/clip-vit-base-patch32")
        let expectedDim = ModelManifest.clipFeatureDimension(for: clipName)
        let modelIDs = ModelManifest.clipBundleIDs(for: clipName)
        try await ModelDownloadService.ensureModelsInstalled(
            profile: profile,
            config: config,
            modelIDs: modelIDs,
            purpose: "Download is required for Search by Text (⌘F) and background indexing.",
            allowDownloadPrompt: allowDownloadPrompt
        )
        guard let cacheManager else { throw CLIPFeatureExtractorError.inferenceFailed }
        let extractor = clipExtractor(for: clipName)

        if !paths.isEmpty {
            progress(0, paths.count, Self.checkingCachedFeaturesLabel(fileCount: paths.count))
        }
        let pathsCopy = paths
        let cacheLookup = await Task.detached {
            Self.partitionCLIPCache(
                paths: pathsCopy,
                cacheManager: cacheManager,
                expectedDimension: expectedDim
            )
        }.value
        var result = cacheLookup.cached
        let needExtract = cacheLookup.needExtract

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
            config: config,
            modelIDs: modelIDs,
            purpose: "Download is required to encode text for Search by Text (⌘F)."
        )
        let extractor = clipExtractor(for: clipName)
        return try await Task.detached {
            try extractor.extractTextFeature(prompt: prompt)
        }.value
    }

    private func fileAttributes(path: String) -> (mtime: Double, size: Int)? {
        Self.fileAttributes(for: path)
    }

    private static func checkingCachedFeaturesLabel(fileCount: Int) -> String {
        "Checking cached features (\(fileCount) files)…"
    }

    nonisolated static func fileAttributes(for path: String) -> (mtime: Double, size: Int)? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let date = values.contentModificationDate,
              let size = values.fileSize else { return nil }
        return (date.timeIntervalSince1970, size)
    }

    nonisolated private static func partitionCNNCache(
        paths: [String],
        cacheManager: FeatureCacheManager,
        resnetModel: String
    ) -> (cached: [String: [Float]], needExtract: [String]) {
        var cached: [String: [Float]] = [:]
        var needExtract: [String] = []
        let expectedDim = ModelManifest.resnetFeatureDimension(for: resnetModel)
        for path in paths {
            guard let attrs = fileAttributes(for: path) else { continue }
            if let feat = cacheManager.getCNN(path: path, mtime: attrs.mtime, size: attrs.size),
               feat.count == expectedDim {
                cached[path] = feat
            } else {
                needExtract.append(path)
            }
        }
        return (cached, needExtract)
    }

    nonisolated private static func partitionCLIPCache(
        paths: [String],
        cacheManager: FeatureCacheManager,
        expectedDimension: Int
    ) -> (cached: [String: [Float]], needExtract: [String]) {
        var cached: [String: [Float]] = [:]
        var needExtract: [String] = []
        for path in paths {
            guard let attrs = fileAttributes(for: path) else { continue }
            if let feat = cacheManager.getCLIP(path: path, mtime: attrs.mtime, size: attrs.size),
               feat.count == expectedDimension {
                cached[path] = feat
            } else {
                needExtract.append(path)
            }
        }
        return (cached, needExtract)
    }
}
