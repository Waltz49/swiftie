import CryptoKit
import Foundation

/// Content identity for LoRA weight files (port of `lora_user_entries` / `lora_compatibility_checker` digest helpers).
enum LoRAWeightsIdentity {
    typealias DigestCache = [String: String]

    /// Catalog paths only (Python ``_entry_path_candidates``); safe on hot UI paths.
    static func catalogPathCandidates(entry: LoRAEntry) -> [URL] {
        var paths: [URL] = []
        for raw in [entry.localPath, entry.sourcePath] {
            let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { continue }
            let url = URL(fileURLWithPath: (text as NSString).expandingTildeInPath).standardizedFileURL
            guard LoRAPathResolver.weightsLikelyOnDisk(at: url) else { continue }
            if !paths.contains(where: { $0.path == url.path }) {
                paths.append(url)
            }
        }
        return paths
    }

    static func entryPathCandidates(loraID: String, entry: LoRAEntry, includeDiscoverFallback: Bool = false) -> [URL] {
        var paths = catalogPathCandidates(entry: entry)
        guard includeDiscoverFallback else { return paths }
        if let resolved = LoRAPathResolver.discoverLocalWeightsPath(loraID: loraID, entry: entry) {
            let resolvedPath = resolved.standardizedFileURL.path
            if !paths.contains(where: { $0.path == resolvedPath }) {
                paths.append(resolved)
            }
        }
        return paths
    }

    static func registeredWeightPaths(lc: [String: Any]) -> Set<String> {
        var paths = Set<String>()
        for entry in LoRACatalog.catalogEntriesSorted(lc: lc) {
            for url in catalogPathCandidates(entry: entry) {
                paths.insert(url.path)
            }
        }
        return paths
    }

    static func sizeConflictSet(paths: [URL]) -> Set<Int> {
        var counts: [Int: Int] = [:]
        for path in paths {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
                  let size = attrs[.size] as? NSNumber else { continue }
            let bytes = size.intValue
            counts[bytes, default: 0] += 1
        }
        return Set(counts.filter { $0.value > 1 }.map(\.key))
    }

    static func weightsContentDigest(
        path: URL,
        digestCache: inout DigestCache,
        hashSizes: Set<Int>
    ) -> String? {
        let expanded = URL(fileURLWithPath: (path.path as NSString).expandingTildeInPath)
        let resolved = expanded.standardizedFileURL
        guard LoRAPathResolver.weightsFileIsValid(resolved) else { return nil }
        return contentDigest(for: resolved, digestCache: &digestCache, hashSizes: hashSizes)
    }

    private static func contentDigest(
        for path: URL,
        digestCache: inout DigestCache,
        hashSizes: Set<Int>
    ) -> String? {
        let key = path.standardizedFileURL.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let sizeNum = attrs[.size] as? NSNumber else { return nil }
        let fileSize = sizeNum.intValue
        if !hashSizes.contains(fileSize) {
            return "size:\(fileSize)"
        }
        if let cached = digestCache[key] { return cached }
        guard let md5 = DuplicateHashService.md5Hex(for: path.path) else { return nil }
        digestCache[key] = md5
        return md5
    }

    static func entryWeightsIdentityKey(
        loraID: String,
        entry: LoRAEntry,
        digestCache: inout DigestCache,
        hashSizes: Set<Int>,
        includeDiscoverFallback: Bool = false
    ) -> String {
        for candidate in entryPathCandidates(loraID: loraID, entry: entry, includeDiscoverFallback: includeDiscoverFallback) {
            if let digest = weightsContentDigest(path: candidate, digestCache: &digestCache, hashSizes: hashSizes) {
                if digest.hasPrefix("size:") { return digest }
                return "md5:\(digest)"
            }
        }
        return "id:\(entry.loraID)"
    }

    static func sameLoraFile(_ a: URL, _ b: URL) -> Bool {
        let aPath = a.standardizedFileURL.path
        let bPath = b.standardizedFileURL.path
        if aPath == bPath { return true }
        guard FileManager.default.fileExists(atPath: aPath),
              FileManager.default.fileExists(atPath: bPath) else { return false }
        return FileManager.default.contentsEqual(atPath: aPath, andPath: bPath)
    }

}