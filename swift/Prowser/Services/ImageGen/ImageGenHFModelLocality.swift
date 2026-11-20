import Foundation

/// Whether pipeline model weights are present locally (port of ``pipeline_model_is_local`` / HF cache walks).
@MainActor
enum ImageGenHFModelLocality {
    private static let fluxWeightSubdirs = ["vae", "transformer", "text_encoder", "text_encoder_2"]
    private static let flux2KleinWeightSubdirs = ["vae", "transformer", "text_encoder"]
    private static let zImageWeightSubdirs = ["vae", "transformer", "text_encoder"]
    private static let sd15WeightSubdirs = ["unet", "text_encoder"]
    private static let sdxlWeightSubdirs = ["unet", "text_encoder", "text_encoder_2", "vae"]
    private static let sd15DefaultVAE = "stabilityai/sd-vae-ft-mse"

    /// Civitai / local .safetensors when HF diffusers layout is not cached (mirrors Python ``SD15_DEFAULT_CHECKPOINT_BY_REPO``).
    private static let sd15DefaultCheckpointByRepo: [String: String] = [
        LoRAHFModelIDs.realisticVisionV6NoVAE: "~/Downloads/Realistic_Vision_V6.0_NV_B1_fp16.safetensors",
    ]

    private static var cache: [String: Bool] = [:]

    static func invalidateCache(repoID: String? = nil, pipelineID: String? = nil) {
        if repoID == nil, pipelineID == nil {
            cache.removeAll()
            return
        }
        let keysToRemove = cache.keys.filter { key in
            let parts = key.split(separator: "\u{1f}", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return false }
            let matchPipeline = pipelineID == nil || parts[0] == pipelineID
            let matchRepo = repoID == nil || parts[1] == repoID
            return matchPipeline && matchRepo
        }
        for key in keysToRemove {
            cache.removeValue(forKey: key)
        }
    }

    static func modelIsInstalled(entry: ImageGenModelDownloadCatalogEntry) -> Bool {
        modelIsInstalled(pipelineID: entry.pipelineID, repoID: entry.repoID, checkpointPath: nil)
    }

    static func modelIsInstalled(
        pipelineID: String,
        repoID: String,
        checkpointPath: String? = nil
    ) -> Bool {
        let key = "\(pipelineID)\u{1f}\(repoID)\u{1f}\(checkpointPath ?? "")"
        if let cached = cache[key] { return cached }
        let result = checkLocal(pipelineID: pipelineID, repoID: repoID, checkpointPath: checkpointPath)
        cache[key] = result
        return result
    }

    /// Default local checkpoint path for a repo (expanded when the file exists).
    static func optionalLocalCheckpointPath(repoID: String, checkpointPath: String? = nil) -> String? {
        resolveSD15CheckpointPath(repoID: repoID, checkpointPath: checkpointPath)
    }

    /// User-facing note when a model can skip HF via a local Civitai checkpoint.
    static func localCheckpointInstallHint(repoID: String) -> String? {
        guard sd15DefaultCheckpointByRepo[repoID] != nil else { return nil }
        let vae = sd15DefaultVAE
        switch repoID {
        case LoRAHFModelIDs.realisticVisionV6NoVAE:
            return """
            Realistic Vision V6.0 B1 can run from a Civitai checkpoint instead of downloading the full Hugging Face repo (~2 GB .safetensors). Put Realistic_Vision_V6.0_NV_B1_fp16.safetensors in ~/Downloads, or set checkpoint path in the Create dialog for this model.

            You still need the SD VAE (\(vae)) — download it from this list if generation says the VAE is missing.
            """
        default:
            return nil
        }
    }

    /// On-disk install root for display (snapshot dir, tier dir, or local path). Nil when not installed.
    static func resolvedInstallPath(pipelineID: String, repoID: String) -> String? {
        switch pipelineID {
        case "flux_schnell_mflux_play":
            return mfluxFluxResolvedPath(repoID: repoID)
        case "mflux_fill_expand", "mflux_fill_infill":
            return newestCompleteSnapshot(repoID: repoID, subdirs: fluxWeightSubdirs)
        case "mflux_flux2_klein_edit", "mflux_flux2_klein_create", "mflux_flux2_klein_expand":
            if ImageGenSceneWorksKlein.isSceneWorksRepo(repoID) {
                return ImageGenSceneWorksKlein.resolveTierModelPath(repoID: repoID, tier: "q4")
            }
            return newestCompleteSnapshot(repoID: repoID, subdirs: flux2KleinWeightSubdirs)
        case "sana_sprint_600m":
            return newestSnapshotWithWeights(repoID: repoID)
        case "mflux_z_image_turbo":
            return newestCompleteSnapshot(repoID: repoID, subdirs: zImageWeightSubdirs)
        case "sd15_diffusers":
            if let main = newestCompleteSnapshot(repoID: repoID, subdirs: sd15WeightSubdirs) {
                if hfRepoSnapshotIsComplete(repoID: repoID, subdirs: ["vae"]) { return main }
                if hfRepoSnapshotHasWeights(repoID: sd15DefaultVAE) { return main }
            }
            return resolveSD15CheckpointPath(repoID: repoID, checkpointPath: nil)
        case "sdxl_diffusers":
            return newestCompleteSnapshot(repoID: repoID, subdirs: sdxlWeightSubdirs)
        default:
            return nil
        }
    }

    private static func mfluxFluxResolvedPath(repoID: String) -> String? {
        let expanded = (repoID as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) { return expanded }
        return newestCompleteSnapshot(repoID: repoID, subdirs: fluxWeightSubdirs)
    }

    private static func newestCompleteSnapshot(repoID: String, subdirs: [String]) -> String? {
        for snapshot in snapshotPaths(repoID: repoID) {
            if snapshotHasComponentWeights(snapshotPath: snapshot, subdirs: subdirs) {
                return snapshot
            }
        }
        return nil
    }

    private static func newestSnapshotWithWeights(repoID: String) -> String? {
        let weightExtensions = [".safetensors", ".bin", ".pt"]
        for snapshot in snapshotPaths(repoID: repoID) {
            if directoryHasWeightFile(at: snapshot, extensions: weightExtensions) {
                return snapshot
            }
        }
        return nil
    }

    private static func checkLocal(
        pipelineID: String,
        repoID: String,
        checkpointPath: String?
    ) -> Bool {
        switch pipelineID {
        case "flux_schnell_mflux_play":
            return mfluxFluxWeightsAreLocal(repoID: repoID)
        case "mflux_fill_expand", "mflux_fill_infill":
            return hfRepoSnapshotIsComplete(repoID: repoID, subdirs: fluxWeightSubdirs)
        case "mflux_flux2_klein_edit", "mflux_flux2_klein_create", "mflux_flux2_klein_expand":
            if ImageGenSceneWorksKlein.isSceneWorksRepo(repoID) {
                return ImageGenSceneWorksKlein.tierIsLocal(repoID: repoID, tier: "q4")
            }
            return hfRepoSnapshotIsComplete(repoID: repoID, subdirs: flux2KleinWeightSubdirs)
        case "sana_sprint_600m":
            return hfRepoSnapshotHasWeights(repoID: repoID)
        case "mflux_z_image_turbo":
            return hfRepoSnapshotIsComplete(repoID: repoID, subdirs: zImageWeightSubdirs)
        case "sd15_diffusers":
            return sd15ModelIsInstalled(repoID: repoID, checkpointPath: checkpointPath)
        case "sdxl_diffusers":
            return hfRepoSnapshotIsComplete(repoID: repoID, subdirs: sdxlWeightSubdirs)
        default:
            return true
        }
    }

    private static func sd15ModelIsInstalled(repoID: String, checkpointPath: String?) -> Bool {
        if hfRepoSnapshotIsComplete(repoID: repoID, subdirs: sd15WeightSubdirs) {
            if hfRepoSnapshotIsComplete(repoID: repoID, subdirs: ["vae"]) { return true }
            return hfRepoSnapshotHasWeights(repoID: sd15DefaultVAE)
        }
        guard resolveSD15CheckpointPath(repoID: repoID, checkpointPath: checkpointPath) != nil else {
            return false
        }
        return hfRepoSnapshotHasWeights(repoID: sd15DefaultVAE)
    }

    private static func resolveSD15CheckpointPath(repoID: String, checkpointPath: String?) -> String? {
        let candidates: [String]
        if let override = checkpointPath?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            candidates = [override]
        } else if let mapped = sd15DefaultCheckpointByRepo[repoID] {
            candidates = [mapped]
        } else {
            return nil
        }
        for raw in candidates {
            let path = (raw as NSString).expandingTildeInPath
            guard isReadableSafetensorsFile(path) else { continue }
            return path
        }
        return nil
    }

    private static func isReadableSafetensorsFile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        guard path.lowercased().hasSuffix(".safetensors") else { return false }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber, size.int64Value > 0 else {
            return false
        }
        return true
    }

    private static func mfluxFluxWeightsAreLocal(repoID: String) -> Bool {
        let expanded = (repoID as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) { return true }
        return hfRepoSnapshotIsComplete(repoID: repoID, subdirs: fluxWeightSubdirs)
    }

    static func hfHubCacheRoot() -> String {
        if let hfHome = ProcessInfo.processInfo.environment["HF_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hfHome.isEmpty {
            return (hfHome as NSString).appendingPathComponent("hub")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".cache/huggingface/hub")
    }

    private static func snapshotPaths(repoID: String) -> [String] {
        let repoCache = (hfHubCacheRoot() as NSString)
            .appendingPathComponent("models--\(repoID.replacingOccurrences(of: "/", with: "--"))/snapshots")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: repoCache) else { return [] }
        return entries
            .map { (repoCache as NSString).appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0) }
            .sorted { lhs, rhs in
                let lm = (try? FileManager.default.attributesOfItem(atPath: lhs)[.modificationDate] as? Date) ?? .distantPast
                let rm = (try? FileManager.default.attributesOfItem(atPath: rhs)[.modificationDate] as? Date) ?? .distantPast
                return lm > rm
            }
    }

    static func hfRepoSnapshotIsComplete(repoID: String, subdirs: [String]) -> Bool {
        for snapshot in snapshotPaths(repoID: repoID) {
            if snapshotHasComponentWeights(snapshotPath: snapshot, subdirs: subdirs) {
                return true
            }
        }
        return false
    }

    static func hfRepoSnapshotHasWeights(repoID: String) -> Bool {
        let weightExtensions = [".safetensors", ".bin", ".pt"]
        for snapshot in snapshotPaths(repoID: repoID) {
            if directoryHasWeightFile(at: snapshot, extensions: weightExtensions) {
                return true
            }
        }
        return false
    }

    private static func snapshotHasComponentWeights(snapshotPath: String, subdirs: [String]) -> Bool {
        for sub in subdirs {
            let component = (snapshotPath as NSString).appendingPathComponent(sub)
            if !componentHasWeights(componentPath: component) { return false }
        }
        return true
    }

    private static func componentHasWeights(componentPath: String) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: componentPath) else {
            return false
        }
        for name in entries {
            if !name.hasSuffix(".safetensors") || name.hasSuffix(".index.json") { continue }
            let full = (componentPath as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue {
                return true
            }
        }
        for indexName in ["diffusion_pytorch_model.safetensors.index.json", "model.safetensors.index.json"] {
            let indexPath = (componentPath as NSString).appendingPathComponent(indexName)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: indexPath)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let weightMap = json["weight_map"] as? [String: Any],
                  !weightMap.isEmpty else { continue }
            let shards = Set(weightMap.values.compactMap { $0 as? String }.filter { !$0.isEmpty })
            guard !shards.isEmpty else { continue }
            for shard in shards {
                let shardPath = (componentPath as NSString).appendingPathComponent(shard)
                if !FileManager.default.fileExists(atPath: shardPath) { return false }
            }
            return true
        }
        return false
    }

    private static func directoryHasWeightFile(at path: String, extensions: [String]) -> Bool {
        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return false }
        for case let name as String in enumerator {
            if extensions.contains(where: { name.hasSuffix($0) }) {
                return true
            }
        }
        return false
    }
}
