import Foundation

/// Marks registry plugins unavailable when this app runs generation only via MFLUX CLI.
@MainActor
enum ImageGenMfluxPluginFilter {
    static func applyingMfluxAvailability(_ plugins: [[String: Any]]) -> [[String: Any]] {
        plugins.map { plugin in
            var copy = plugin
            let pipeline = plugin["pipeline_id"] as? String ?? ""
            let hfModel = plugin["hf_model_id"] as? String ?? ""
            let registryOK = plugin["available"] as? Bool ?? true
            var mfluxOK = !pipeline.isEmpty
                && MfluxCLIPipeline.isSupported(pipelineID: pipeline)
                && MfluxToolchain.shared.isPipelineInstalled(pipeline)
            if mfluxOK, ImageGenSceneWorksKlein.isSceneWorksRepo(hfModel) {
                let tier = ImageGenSceneWorksKlein.normalizeMLXTier(plugin["mlx_tier"])
                mfluxOK = ImageGenSceneWorksKlein.tierIsLocal(repoID: hfModel, tier: tier)
            }
            copy["available"] = registryOK && mfluxOK
            if registryOK && !mfluxOK {
                copy["unavailable_reason"] = "Requires MFLUX CLI for this model (Settings → Image Generation)."
            }
            return copy
        }
    }
}
