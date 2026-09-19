import Foundation

/// Distance / similarity helpers for feature vectors (port of CNN sorter metrics).
enum SimilarityOrdering {
    enum Metric: String, Sendable {
        case cosine
        case euclidean
        case manhattan

        static func fromSettings(_ raw: String) -> Metric {
            switch raw.lowercased() {
            case "euclidean": return .euclidean
            case "manhattan": return .manhattan
            default: return .cosine
            }
        }
    }

    static func distance(_ a: [Float], _ b: [Float], metric: Metric) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .greatestFiniteMagnitude }
        switch metric {
        case .cosine:
            return 1 - cosineSimilarity(a, b)
        case .euclidean:
            var sum: Float = 0
            for i in 0 ..< a.count {
                let d = a[i] - b[i]
                sum += d * d
            }
            return sqrt(sum)
        case .manhattan:
            var sum: Float = 0
            for i in 0 ..< a.count {
                sum += abs(a[i] - b[i])
            }
            return sum
        }
    }

    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in 0 ..< a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = sqrt(na) * sqrt(nb)
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    /// Order by similarity to reference(s). Matches Python `_score_candidates_vectorized` + aggregate ref mean.
    static func orderBySimilarity(
        paths: [String],
        features: [String: [Float]],
        referencePaths: [String],
        metric: Metric
    ) -> [String] {
        let refKeys = Set(referencePaths.compactMap { ImageRecognitionPath.normalize($0) ?? $0 })
        let refFeats: [[Float]] = referencePaths.compactMap { path in
            let key = ImageRecognitionPath.normalize(path) ?? path
            return features[key] ?? features[path]
        }
        guard !refFeats.isEmpty else { return paths }

        let aggregate = aggregateReference(refFeats)
        let validRefSet = refKeys

        var scored: [(similarity: Float, path: String)] = []
        var missing: [String] = []
        for path in paths {
            let key = ImageRecognitionPath.normalize(path) ?? path
            guard let feat = features[key] ?? features[path] else {
                missing.append(path)
                continue
            }
            let sim: Float
            if validRefSet.contains(key) || validRefSet.contains(path) {
                sim = 1
            } else {
                sim = similarityScore(candidate: feat, reference: aggregate, metric: metric)
            }
            scored.append((sim, path))
        }
        scored.sort { $0.similarity > $1.similarity }
        return scored.map(\.path) + missing
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

    /// Higher = more similar (Python `_compute_similarity` / vectorized branch).
    private static func similarityScore(candidate: [Float], reference: [Float], metric: Metric) -> Float {
        guard candidate.count == reference.count, !candidate.isEmpty else { return -.greatestFiniteMagnitude }
        switch metric {
        case .cosine:
            return cosineSimilarity(candidate, reference)
        case .euclidean:
            let dist = distance(candidate, reference, metric: .euclidean)
            let featDim = Float(reference.count)
            let normalized = featDim > 0 ? dist / sqrt(featDim) : dist
            return -normalized
        case .manhattan:
            let dist = distance(candidate, reference, metric: .manhattan)
            let featDim = Float(reference.count)
            let normalized = featDim > 0 ? dist / featDim : dist
            return -normalized
        }
    }

    /// CLIP text search: filter by minimum cosine similarity, sort descending.
    static func clipTextRanked(
        paths: [String],
        features: [String: [Float]],
        textFeature: [Float],
        minimumSimilarity: Float
    ) -> [String] {
        let scored: [(String, Float)] = paths.compactMap { path in
            let key = ImageRecognitionPath.normalize(path) ?? path
            guard let feat = features[key] ?? features[path] else { return nil }
            let sim = cosineSimilarity(feat, textFeature)
            guard sim >= minimumSimilarity else { return nil }
            return (path, sim)
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }

    static func highestClipSimilarity(
        paths: [String],
        features: [String: [Float]],
        textFeature: [Float]
    ) -> Float? {
        var best: Float?
        for path in paths {
            let key = ImageRecognitionPath.normalize(path) ?? path
            guard let feat = features[key] ?? features[path] else { continue }
            let sim = cosineSimilarity(feat, textFeature)
            if best == nil || sim > best! { best = sim }
        }
        return best
    }
}
