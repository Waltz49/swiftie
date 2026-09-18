import CryptoKit
import Foundation

/// MD5 duplicate grouping. Port of `file_ops/duplicate_hash.py`.
enum DuplicateHashService {
    static let workerMinPaths = 80

    struct HashGroups: Sendable {
        var hashToFiles: [String: [String]]
        var fileToHash: [String: String]
    }

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

    /// Hash each path and group by digest. Returns cancelled when `shouldCancel` is true.
    static func buildHashGroups(
        filePaths: [String],
        shouldCancel: @escaping @Sendable () -> Bool = { false },
        progress: @escaping @Sendable (Int, Int, String) -> Void = { _, _, _ in }
    ) -> (HashGroups, cancelled: Bool) {
        var hashToFiles: [String: [String]] = [:]
        var fileToHash: [String: String] = [:]
        let total = filePaths.count
        var cancelled = false

        for (idx, filePath) in filePaths.enumerated() {
            if shouldCancel() {
                cancelled = true
                break
            }
            if total > 0 {
                let name = (filePath as NSString).lastPathComponent
                progress(
                    idx,
                    total,
                    "Hashing \(name)... (\(idx + 1)/\(total))"
                )
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: filePath, isDirectory: &isDir),
                  !isDir.boolValue else { continue }
            guard let fileHash = md5Hex(for: filePath) else { continue }
            fileToHash[filePath] = fileHash
            hashToFiles[fileHash, default: []].append(filePath)
        }

        if !cancelled, total > 0 {
            progress(total, total, "")
        }
        return (HashGroups(hashToFiles: hashToFiles, fileToHash: fileToHash), cancelled)
    }

    /// Sorted `(hash, path)` pairs for files that belong to a group of 2+ identical files.
    static func duplicateGroupPairs(from groups: HashGroups) -> [(hash: String, path: String)] {
        var pairs: [(String, String)] = []
        for (_, files) in groups.hashToFiles where files.count > 1 {
            let sorted = files.sorted()
            guard let hash = groups.fileToHash[sorted[0]] else { continue }
            for path in sorted {
                pairs.append((hash, path))
            }
        }
        pairs.sort { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            return lhs.1 < rhs.1
        }
        return pairs.map { (hash: $0.0, path: $0.1) }
    }

    static func duplicateGroupPairs(_ paths: [String]) -> [(hash: String, path: String)] {
        let (groups, _) = buildHashGroups(filePaths: paths)
        return duplicateGroupPairs(from: groups)
    }

    /// Groups paths by MD5; returns only groups with 2+ files, flattened in stable group order.
    static func duplicateSortedPaths(_ paths: [String]) -> [String] {
        duplicateGroupPairs(paths).map(\.path)
    }
}
