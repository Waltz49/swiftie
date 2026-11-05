import Foundation

/// Model id + label for job cards and EXIF (port of ``_generation_model_id_for_status`` / ``model_display_name``).
enum ImageGenModelDisplay {
    /// Hugging Face repo id for job cards, EXIF, and timing keys.
    /// Prefer the registry plugin's ``hf_model_id`` when set (matches Python ``build_worker_payload`` and
    /// avoids stale ``hf_model_id`` in queue values after Replace). Fall back to ``effective`` when the
    /// plugin id is empty. Python ``_generation_model_id_for_status`` reads values first; Swift prefers
    /// the plugin when registered so cards match what the worker runs.
    static func generationModelID(plugin: ImageGenPluginDescriptor, effective: [String: Any]) -> String {
        let pluginHF = plugin.hfModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pluginHF.isEmpty {
            return pluginHF
        }
        let raw = (effective["hf_model_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.contains("/") {
            return raw
        }
        return pluginHF
    }

    static func modelDisplayName(pipelineID: String, hfModelID: String) -> String {
        let hf = hfModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if pipelineID == "flux_schnell_mflux_play" {
            let tail = hf.split(separator: "/").last.map(String.init) ?? hf
            if tail.contains("FLUX.1-") {
                let variant = tail.split(separator: "FLUX.1-", maxSplits: 1).last.map(String.init) ?? tail
                return "FLUX.1 \(variant.replacingOccurrences(of: "-", with: " "))"
            }
            return tail.replacingOccurrences(of: "-", with: " ")
        }
        if pipelineID == "sana_sprint_600m" {
            if hf.contains("/") {
                return hf.split(separator: "/").last.map(String.init)?.replacingOccurrences(of: "_", with: " ") ?? hf
            }
            return "SANA Sprint 0.6B 1024px"
        }
        if pipelineID == "mflux_z_image_turbo" || pipelineID == "z_image_turbo_sdnq" {
            if hf == LoRAHFModelIDs.zImageTurboMflux4Bit || hf.lowercased().contains("mflux-4bit") {
                return LoRAHFModelIDs.displayName(for: LoRAHFModelIDs.zImageTurboMflux4Bit)
            }
            if hf == LoRAHFModelIDs.zImageTurbo || hf.isEmpty {
                return LoRAHFModelIDs.displayName(for: LoRAHFModelIDs.zImageTurbo)
            }
            return LoRAHFModelIDs.displayName(for: hf)
        }
        if pipelineID == "sd15_diffusers" {
            if hf.contains("/") {
                return hf.split(separator: "/").last.map(String.init)?.replacingOccurrences(of: "_", with: " ") ?? hf
            }
            return "Stable Diffusion 1.5"
        }
        if pipelineID == "sdxl_diffusers" {
            if hf.contains("/") {
                return hf.split(separator: "/").last.map(String.init)?
                    .replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "-", with: " ") ?? hf
            }
            return "Stable Diffusion XL 1.0"
        }
        if pipelineID == "mflux_fill_expand" || pipelineID == "mflux_fill_infill" {
            if hf.contains("/") {
                return hf.split(separator: "/").last.map(String.init)?
                    .replacingOccurrences(of: ".", with: " ")
                    .replacingOccurrences(of: "-", with: " ") ?? hf
            }
            return "FLUX.1 Fill"
        }
        if pipelineID == "mflux_flux2_klein_create"
            || pipelineID == "mflux_flux2_klein_edit"
            || pipelineID == "mflux_flux2_klein_expand" {
            if ImageGenSceneWorksKlein.isSceneWorksRepo(hf) {
                return "FLUX 2 Klein 9B KV MLX"
            }
            let lower = hf.lowercased()
            if lower.contains("9b-kv") || lower.contains("klein-9b-kv") || lower.contains("flux.2-klein-9b-kv") {
                return "FLUX 2 klein 9B KV"
            }
            if lower.contains("9b") {
                return "FLUX 2 klein 9B"
            }
            if lower.contains("4b") {
                return "FLUX 2 klein 4B"
            }
            if hf.contains("/") {
                return hf.split(separator: "/").last.map(String.init)?
                    .replacingOccurrences(of: ".", with: " ")
                    .replacingOccurrences(of: "-", with: " ") ?? hf
            }
            return "FLUX.2 Klein 4B"
        }
        let menu = ImageGenExifCommentFormatting.menuLabelForHFModelId(hf)
        return menu.isEmpty ? hf : menu
    }

    static func sanitizeJobValues(pluginID: String, values: [String: Any]) -> [String: Any] {
        guard let plugin = ImageGenPluginCatalog.plugin(pluginID: pluginID) else { return values }
        var out = values
        out["hf_model_id"] = plugin.hfModelID
        return out
    }
}
