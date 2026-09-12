import Foundation

/// Parse face embeddings/coordinates from Python JSON IPC (`[NSNumber]` arrays).
enum FaceEncodingJSON {
    static func parseEmbedding(_ value: Any?) -> [Double]? {
        guard let raw = value as? [Any], !raw.isEmpty else { return nil }
        let embedding = raw.compactMap { element -> Double? in
            if let value = element as? Double { return value }
            if let value = element as? Int { return Double(value) }
            if let value = element as? NSNumber { return value.doubleValue }
            return nil
        }
        guard embedding.count == 128 else { return nil }
        return embedding
    }

    static func parseTRBL(_ value: Any?) -> [Int]? {
        guard let raw = value as? [Any], raw.count == 4 else { return nil }
        let trbl = raw.compactMap { element -> Int? in
            if let value = element as? Int { return value }
            if let value = element as? NSNumber { return value.intValue }
            return nil
        }
        guard trbl.count == 4 else { return nil }
        return trbl
    }
}
