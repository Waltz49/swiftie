import CryptoKit
import Foundation

/// MD5 duplicate grouping. Port of `file_ops/duplicate_hash.py`.
enum DuplicateHashService {
    static func md5Hex(for path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        while true {
            let data = handle.readData(ofLength: 4096)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Groups paths by MD5; returns only groups with 2+ files, flattened in stable group order.
    static func duplicateSortedPaths(_ paths: [String]) -> [String] {
        var groups: [String: [String]] = [:]
        for path in paths {
            guard let hash = md5Hex(for: path) else { continue }
            groups[hash, default: []].append(path)
        }
        let duplicateGroups = groups.values.filter { $0.count > 1 }.sorted { $0[0] < $1[0] }
        return duplicateGroups.flatMap { $0.sorted() }
    }
}
