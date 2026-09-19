import Foundation

/// Debug logging for ⌘K / ⌘F (Settings → Debug mode or `--debug`). Prefix matches Python `similarity_search_log.py`.
@MainActor
enum SimilaritySearchLog {
    private static let prefix = "[similarity_search]"

    static func log(_ config: AppConfig, _ message: String) {
        config.debugLog("\(prefix) \(message)")
    }

    static func logScope(
        config: AppConfig,
        kind: String,
        candidateCount: Int,
        recursive: Bool,
        searchDirectory: String?,
        filterPattern: String,
        searchDepth: Int,
        referencePaths: [String],
        extra: String = ""
    ) {
        let refSummary: String
        if referencePaths.count == 1, let one = referencePaths.first {
            refSummary = "\((one as NSString).lastPathComponent) (\(one))"
        } else {
            refSummary = "\(referencePaths.count) refs"
        }
        var line =
            "\(kind) scope candidates=\(candidateCount) recursive=\(recursive) "
            + "search_dir=\(searchDirectory ?? "(current)") filter=\(filterPattern) "
            + "search_depth=\(searchDepth) reference=\(refSummary)"
        if !extra.isEmpty { line += " \(extra)" }
        log(config, line)
    }

    static func logFeatureSummary(
        config: AppConfig,
        kind: String,
        candidateCount: Int,
        indexedCount: Int,
        featureDimension: Int?,
        modelLabel: String,
        metric: String? = nil
    ) {
        var line =
            "\(kind) features indexed=\(indexedCount)/\(candidateCount) model=\(modelLabel)"
        if let featureDimension { line += " dim=\(featureDimension)" }
        if let metric { line += " metric=\(metric)" }
        log(config, line)
    }

    static func logTopCNNScores(
        config: AppConfig,
        paths: [String],
        features: [String: [Float]],
        referencePaths: [String],
        metric: SimilarityOrdering.Metric,
        limit: Int = 15
    ) {
        guard config.bool(forKey: "debug_mode") else { return }
        let refFeats: [[Float]] = referencePaths.compactMap { path in
            let key = ImageRecognitionPath.normalize(path) ?? path
            return features[key] ?? features[path]
        }
        guard !refFeats.isEmpty else {
            log(config, "CNN top scores: no reference features")
            return
        }
        let aggregate = aggregateReference(refFeats)
        let refKeys = Set(referencePaths.compactMap { ImageRecognitionPath.normalize($0) ?? $0 })
        var scored: [(Float, String)] = []
        for path in paths {
            let key = ImageRecognitionPath.normalize(path) ?? path
            guard let feat = features[key] ?? features[path] else { continue }
            let sim: Float
            if refKeys.contains(key) || refKeys.contains(path) {
                sim = 1
            } else {
                sim = cnnSimilarityScore(candidate: feat, reference: aggregate, metric: metric)
            }
            scored.append((sim, path))
        }
        scored.sort { $0.0 > $1.0 }
        log(config, "CNN top \(min(limit, scored.count)) scores:")
        for (index, item) in scored.prefix(limit).enumerated() {
            let name = (item.1 as NSString).lastPathComponent
            log(config, String(format: "  %2d  %.4f  %@  %@", index, item.0, name, item.1))
        }
    }

    static func logTopCLIPScores(
        config: AppConfig,
        paths: [String],
        features: [String: [Float]],
        textFeature: [Float],
        threshold: Float,
        limit: Int = 15
    ) {
        guard config.bool(forKey: "debug_mode") else { return }
        var scored: [(Float, String)] = []
        for path in paths {
            let key = ImageRecognitionPath.normalize(path) ?? path
            guard let feat = features[key] ?? features[path] else { continue }
            let sim = SimilarityOrdering.cosineSimilarity(feat, textFeature)
            scored.append((sim, path))
        }
        scored.sort { $0.0 > $1.0 }
        log(config, "CLIP text top \(min(limit, scored.count)) scores (threshold=\(String(format: "%.2f", threshold))):")
        for (index, item) in scored.prefix(limit).enumerated() {
            let name = (item.1 as NSString).lastPathComponent
            log(config, String(format: "  %2d  %.4f  %@  %@", index, item.0, name, item.1))
        }
        let pass = scored.filter { $0.0 >= threshold }.count
        log(config, "CLIP matched \(pass)/\(scored.count) at threshold")
    }

    private static func aggregateReference(_ refFeats: [[Float]]) -> [Float] {
        guard refFeats.count > 1 else { return refFeats[0] }
        let dim = refFeats[0].count
        var mean = [Float](repeating: 0, count: dim)
        for ref in refFeats {
            guard ref.count == dim else { continue }
            for i in 0 ..< dim { mean[i] += ref[i] }
        }
        let n = Float(refFeats.count)
        for i in 0 ..< dim { mean[i] /= n }
        return mean
    }

    private static func cnnSimilarityScore(candidate: [Float], reference: [Float], metric: SimilarityOrdering.Metric) -> Float {
        switch metric {
        case .cosine:
            return SimilarityOrdering.cosineSimilarity(candidate, reference)
        case .euclidean:
            let dist = SimilarityOrdering.distance(candidate, reference, metric: .euclidean)
            let featDim = Float(reference.count)
            return featDim > 0 ? -dist / sqrt(featDim) : -dist
        case .manhattan:
            let dist = SimilarityOrdering.distance(candidate, reference, metric: .manhattan)
            let featDim = Float(reference.count)
            return featDim > 0 ? -dist / featDim : -dist
        }
    }
}
