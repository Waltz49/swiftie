import Foundation

/// SceneWorks FLUX.2 Klein 9B KV MLX tier paths (port of ``sceneworks_klein_mlx``).
enum ImageGenSceneWorksKlein {
    static let repoID = "SceneWorks/flux2-klein-9b-kv-mlx"

    private static let weightSubdirs = ["vae", "transformer", "text_encoder"]
    private static let validTiers: Set<String> = ["q4", "q8", "bf16"]

    static func isSceneWorksRepo(_ hfModelID: String) -> Bool {
        hfModelID.trimmingCharacters(in: .whitespacesAndNewlines) == repoID
    }

    static func normalizeMLXTier(_ value: Any?) -> String {
        let tier = (value as? String ?? "q4").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return validTiers.contains(tier) ? tier : "q4"
    }

    static func resolveTierModelPath(repoID: String, tier: String) -> String? {
        let normalizedTier = normalizeMLXTier(tier)
        for snapshot in hfSnapshotDirs(repoID: repoID) {
            let tierRoot = (snapshot as NSString).appendingPathComponent(normalizedTier)
            if tierHasWeights(tierRoot: tierRoot) {
                return tierRoot
            }
        }
        return nil
    }

    static func tierIsLocal(repoID: String, tier: String) -> Bool {
        resolveTierModelPath(repoID: repoID, tier: tier) != nil
    }

    private static func hfSnapshotDirs(repoID: String) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let repoCache = (home as NSString)
            .appendingPathComponent(".cache/huggingface/hub")
            .appending("/models--\(repoID.replacingOccurrences(of: "/", with: "--"))/snapshots")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: repoCache) else {
            return []
        }
        let paths = entries.map { (repoCache as NSString).appendingPathComponent($0) }
        return paths.filter { FileManager.default.fileExists(atPath: $0) }
            .sorted { lhs, rhs in
                let lm = (try? FileManager.default.attributesOfItem(atPath: lhs)[.modificationDate] as? Date) ?? .distantPast
                let rm = (try? FileManager.default.attributesOfItem(atPath: rhs)[.modificationDate] as? Date) ?? .distantPast
                return lm > rm
            }
    }

    private static func tierHasWeights(tierRoot: String) -> Bool {
        for sub in weightSubdirs {
            let component = (tierRoot as NSString).appendingPathComponent(sub)
            guard componentHasSafetensors(component) else { return false }
        }
        return true
    }

    private static func componentHasSafetensors(_ path: String) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return false
        }
        for name in entries where name.hasSuffix(".safetensors") && !name.hasSuffix(".index.json") {
            let full = (path as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: full) { return true }
        }
        return false
    }
}
