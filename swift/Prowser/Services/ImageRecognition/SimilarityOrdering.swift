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

    /// Order paths by increasing distance to reference feature(s) (mean distance when multiple refs).
    static func orderBySimilarity(
        paths: [String],
        features: [String: [Float]],
        referencePaths: [String],
        metric: Metric
    ) -> [String] {
        let refs = referencePaths.compactMap { features[$0] }
        guard !refs.isEmpty else { return paths }

        func score(for path: String) -> Float {
            guard let feat = features[path] else { return .greatestFiniteMagnitude }
            if refs.count == 1 {
                return distance(feat, refs[0], metric: metric)
            }
            var total: Float = 0
            for ref in refs {
                total += distance(feat, ref, metric: metric)
            }
            return total / Float(refs.count)
        }

        return paths.sorted { score(for: $0) < score(for: $1) }
    }

    /// CLIP text search: filter by minimum cosine similarity, sort descending.
    static func clipTextRanked(
        paths: [String],
        features: [String: [Float]],
        textFeature: [Float],
        minimumSimilarity: Float
    ) -> [String] {
        let scored: [(String, Float)] = paths.compactMap { path in
            guard let feat = features[path] else { return nil }
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
            guard let feat = features[path] else { continue }
            let sim = cosineSimilarity(feat, textFeature)
            if best == nil || sim > best! { best = sim }
        }
        return best
    }
}
