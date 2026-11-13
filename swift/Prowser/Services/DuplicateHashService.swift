import CryptoKit
import Foundation

/// MD5 duplicate grouping. Port of `file_ops/duplicate_hash.py`.
enum DuplicateHashService {
    static let workerMinPaths = 80

    struct HashGroups: Sendable {
        var hashToFiles: [String: [String]]
        var fileToHash: [String: String]
    }

    struct DuplicateSortResult: Sendable {
        var sortedPaths: [String]
        var hashGroups: HashGroups
    }

    #if DEBUG
    static var buildHashGroupsInvocationCountForTesting = 0

    static func resetBuildHashGroupsInvocationCountForTesting() {
        buildHashGroupsInvocationCountForTesting = 0
    }
    #endif

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
        #if DEBUG
        buildHashGroupsInvocationCountForTesting += 1
        #endif
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
            ingestFileHash(path: filePath, into: &hashToFiles, fileToHash: &fileToHash)
        }

        if !cancelled, total > 0 {
            progress(total, total, "")
        }
        return (HashGroups(hashToFiles: hashToFiles, fileToHash: fileToHash), cancelled)
    }

    /// One MD5 pass over `filePaths`; derive duplicate sort order and hash groups together.
    static func duplicateSortResult(filePaths: [String], reversed: Bool) -> DuplicateSortResult {
        let (groups, _) = buildHashGroups(filePaths: filePaths)
        var sorted = duplicateGroupPairs(from: groups).map(\.path)
        if reversed {
            sorted.reverse()
        }
        return DuplicateSortResult(sortedPaths: sorted, hashGroups: groups)
    }

    /// Adds digests for `paths` not already in `base` (no re-read of known paths).
    static func mergingHashGroups(_ base: HashGroups, hashingPaths paths: [String]) -> HashGroups {
        var groups = base
        for path in paths where groups.fileToHash[path] == nil {
            ingestFileHash(path: path, into: &groups.hashToFiles, fileToHash: &groups.fileToHash)
        }
        return groups
    }

    /// Section/thumbnail metadata for a displayed list; matches `duplicateGroupPairs(sorted)` without re-hashing known paths.
    static func groupPairs(
        forDisplayedPaths displayedPaths: [String],
        hashGroups base: HashGroups
    ) -> [(hash: String, path: String)] {
        let merged = mergingHashGroups(base, hashingPaths: displayedPaths)
        return duplicateGroupPairs(from: merged)
    }

    static func duplicateSections(
        forDisplayedPaths paths: [String],
        sortHashGroups: HashGroups?
    ) -> [DuplicateGroupPresentation.DuplicateSection] {
        let base = sortHashGroups ?? HashGroups(hashToFiles: [:], fileToHash: [:])
        let pairs = groupPairs(forDisplayedPaths: paths, hashGroups: base)
        return DuplicateGroupPresentation.duplicateSections(from: pairs)
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
        let result = duplicateSortResult(filePaths: paths, reversed: false)
        return duplicateGroupPairs(from: result.hashGroups)
    }

    /// Groups paths by MD5; returns only groups with 2+ files, flattened in stable group order.
    static func duplicateSortedPaths(_ paths: [String], reversed: Bool = false) -> [String] {
        duplicateSortResult(filePaths: paths, reversed: reversed).sortedPaths
    }

    private static func ingestFileHash(
        path: String,
        into hashToFiles: inout [String: [String]],
        fileToHash: inout [String: String]
    ) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              !isDir.boolValue else { return }
        guard let fileHash = md5Hex(for: path) else { return }
        fileToHash[path] = fileHash
        hashToFiles[fileHash, default: []].append(path)
    }
}
