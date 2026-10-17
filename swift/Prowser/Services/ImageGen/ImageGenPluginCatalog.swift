import Foundation

/// Swift source of truth for image-gen model plugins (metadata for status, dialog, payloads).
struct ImageGenPluginDescriptor: Sendable {
    let pluginID: String
    let pipelineID: String
    let function: String
    let displayName: String
    let hfModelID: String
    let loraHostID: String?
    let quantizeStatusKey: String
    let reportsQuantization: Bool

    init(
        pluginID: String,
        pipelineID: String,
        function: String,
        displayName: String,
        hfModelID: String,
        loraHostID: String? = nil,
        quantizeStatusKey: String = "mflux_quantize",
        reportsQuantization: Bool? = nil
    ) {
        self.pluginID = pluginID
        self.pipelineID = pipelineID
        self.function = function
        self.displayName = displayName
        self.hfModelID = hfModelID
        self.loraHostID = loraHostID
        self.quantizeStatusKey = quantizeStatusKey
        if let reportsQuantization {
            self.reportsQuantization = reportsQuantization
        } else {
            self.reportsQuantization = ImageGenPipelineModeMetadata.reportsQuantization(pipelineID: pipelineID)
        }
    }
}

enum ImageGenPluginCatalog {
    private static let plugins: [ImageGenPluginDescriptor] = [
        .init(
            pluginID: "flux_schnell_mflux",
            pipelineID: "flux_schnell_mflux_play",
            function: "create",
            displayName: "FLUX.1 Schnell MFLUX",
            hfModelID: "black-forest-labs/FLUX.1-schnell",
            loraHostID: "flux1_t2i"
        ),
        .init(
            pluginID: "flux_sldr_nsfw_v2_lora",
            pipelineID: "flux_schnell_mflux_play",
            function: "create",
            displayName: "FLUX SLDR NSFW v2 LoRA",
            hfModelID: "black-forest-labs/FLUX.1-schnell",
            loraHostID: "flux1_t2i"
        ),
        .init(
            pluginID: "sana_sprint_600m",
            pipelineID: "sana_sprint_600m",
            function: "create",
            displayName: "SANA Sprint 600M",
            hfModelID: "Efficient-Large-Model/Sana_Sprint_600M_1024px_diffusers",
            reportsQuantization: false
        ),
        .init(
            pluginID: "z_image_turbo_mflux_4bit",
            pipelineID: "mflux_z_image_turbo",
            function: "create",
            displayName: "Z-Image Turbo",
            hfModelID: "Tongyi-MAI/Z-Image-Turbo",
            loraHostID: "z_image_turbo"
        ),
        .init(
            pluginID: "realistic_vision_v4_sd15",
            pipelineID: "sd15_diffusers",
            function: "create",
            displayName: "Realistic Vision V4.0",
            hfModelID: "SG161222/Realistic_Vision_V4.0_noVAE",
            loraHostID: "sd15",
            reportsQuantization: false
        ),
        .init(
            pluginID: "anything_furry_sd15",
            pipelineID: "sd15_diffusers",
            function: "create",
            displayName: "Anything Furry",
            hfModelID: "stablediffusionapi/anythingfurry",
            loraHostID: "sd15",
            reportsQuantization: false
        ),
        .init(
            pluginID: "sd15_base_v1_5",
            pipelineID: "sd15_diffusers",
            function: "create",
            displayName: "SD 1.5 Base",
            hfModelID: "stable-diffusion-v1-5/stable-diffusion-v1-5",
            loraHostID: "sd15",
            reportsQuantization: false
        ),
        .init(
            pluginID: "sdxl_base_1_0",
            pipelineID: "sdxl_diffusers",
            function: "create",
            displayName: "SDXL 1.0 Base",
            hfModelID: "stabilityai/stable-diffusion-xl-base-1.0",
            loraHostID: "sdxl",
            reportsQuantization: false
        ),
        .init(
            pluginID: "flux_fill_expand",
            pipelineID: "mflux_fill_expand",
            function: "expand",
            displayName: "FLUX.1 Fill expand",
            hfModelID: "black-forest-labs/FLUX.1-Fill-dev",
            loraHostID: "flux1_fill"
        ),
        .init(
            pluginID: "flux_fill_infill",
            pipelineID: "mflux_fill_infill",
            function: "infill",
            displayName: "FLUX.1 Fill infill",
            hfModelID: "black-forest-labs/FLUX.1-Fill-dev",
            loraHostID: "flux1_fill"
        ),
        .init(
            pluginID: "flux_klein_4b_create",
            pipelineID: "mflux_flux2_klein_create",
            function: "create",
            displayName: "FLUX.2 Klein 4B",
            hfModelID: "black-forest-labs/FLUX.2-klein-4B",
            loraHostID: "flux2_klein"
        ),
        .init(
            pluginID: "flux_klein_9b_create",
            pipelineID: "mflux_flux2_klein_create",
            function: "create",
            displayName: "FLUX.2 Klein 9B",
            hfModelID: "black-forest-labs/FLUX.2-klein-9B",
            loraHostID: "flux2_klein"
        ),
        .init(
            pluginID: "flux_klein_9b_kv_create",
            pipelineID: "mflux_flux2_klein_create",
            function: "create",
            displayName: "FLUX.2 Klein 9B KV",
            hfModelID: "black-forest-labs/FLUX.2-klein-9b-kv",
            loraHostID: "flux2_klein"
        ),
        .init(
            pluginID: "flux_klein_4b_edit",
            pipelineID: "mflux_flux2_klein_edit",
            function: "edit",
            displayName: "FLUX.2 Klein 4B edit",
            hfModelID: "black-forest-labs/FLUX.2-klein-4B",
            loraHostID: "flux2_klein"
        ),
        .init(
            pluginID: "flux_klein_9b_edit",
            pipelineID: "mflux_flux2_klein_edit",
            function: "edit",
            displayName: "FLUX.2 Klein 9B edit",
            hfModelID: "black-forest-labs/FLUX.2-klein-9B",
            loraHostID: "flux2_klein"
        ),
        .init(
            pluginID: "flux_klein_9b_kv_edit",
            pipelineID: "mflux_flux2_klein_edit",
            function: "edit",
            displayName: "FLUX.2 Klein 9B KV edit",
            hfModelID: "black-forest-labs/FLUX.2-klein-9b-kv",
            loraHostID: "flux2_klein"
        ),
        .init(
            pluginID: "flux_klein_4b_expand",
            pipelineID: "mflux_flux2_klein_expand",
            function: "expand",
            displayName: "FLUX.2 Klein 4B expand",
            hfModelID: "black-forest-labs/FLUX.2-klein-4B",
            loraHostID: "flux2_klein"
        ),
        .init(
            pluginID: "flux_klein_9b_expand",
            pipelineID: "mflux_flux2_klein_expand",
            function: "expand",
            displayName: "FLUX.2 Klein 9B expand",
            hfModelID: "black-forest-labs/FLUX.2-klein-9B",
            loraHostID: "flux2_klein"
        ),
        .init(
            pluginID: "flux_klein_9b_kv_expand",
            pipelineID: "mflux_flux2_klein_expand",
            function: "expand",
            displayName: "FLUX.2 Klein 9B KV expand",
            hfModelID: "black-forest-labs/FLUX.2-klein-9b-kv",
            loraHostID: "flux2_klein"
        ),
        .init(
            pluginID: "sceneworks_klein_9b_kv_mlx_create",
            pipelineID: "mflux_flux2_klein_create",
            function: "create",
            displayName: "SceneWorks Klein 9B KV MLX",
            hfModelID: "SceneWorks/flux2-klein-9b-kv-mlx",
            loraHostID: "flux2_klein",
            quantizeStatusKey: "mlx_tier"
        ),
        .init(
            pluginID: "sceneworks_klein_9b_kv_mlx_edit",
            pipelineID: "mflux_flux2_klein_edit",
            function: "edit",
            displayName: "SceneWorks Klein 9B KV MLX edit",
            hfModelID: "SceneWorks/flux2-klein-9b-kv-mlx",
            loraHostID: "flux2_klein",
            quantizeStatusKey: "mlx_tier"
        ),
        .init(
            pluginID: "sceneworks_klein_9b_kv_mlx_expand",
            pipelineID: "mflux_flux2_klein_expand",
            function: "expand",
            displayName: "SceneWorks Klein 9B KV MLX expand",
            hfModelID: "SceneWorks/flux2-klein-9b-kv-mlx",
            loraHostID: "flux2_klein",
            quantizeStatusKey: "mlx_tier"
        ),
    ]

    private static let byID: [String: ImageGenPluginDescriptor] = {
        Dictionary(uniqueKeysWithValues: plugins.map { ($0.pluginID, $0) })
    }()

    static func plugin(pluginID: String) -> ImageGenPluginDescriptor? {
        byID[pluginID.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    static func allPlugins() -> [ImageGenPluginDescriptor] { plugins }

    static func plugins(function: String) -> [ImageGenPluginDescriptor] {
        plugins.filter { $0.function == function }
    }
}

/// Pipeline display metadata (port of ``image_gen_pipeline_modes.PipelineMode`` subset).
enum ImageGenPipelineModeMetadata {
    struct Mode {
        let promptStatusLabel: String
        let requiresSourceImage: Bool
        let includesOutputDimensions: Bool
    }

    private static let modes: [String: Mode] = [
        "flux_schnell_mflux_play": Mode(promptStatusLabel: "Prompt:", requiresSourceImage: false, includesOutputDimensions: true),
        "sana_sprint_600m": Mode(promptStatusLabel: "Prompt:", requiresSourceImage: false, includesOutputDimensions: true),
        "z_image_turbo_sdnq": Mode(promptStatusLabel: "Prompt:", requiresSourceImage: false, includesOutputDimensions: true),
        "mflux_z_image_turbo": Mode(promptStatusLabel: "Prompt:", requiresSourceImage: false, includesOutputDimensions: true),
        "sd15_diffusers": Mode(promptStatusLabel: "Prompt:", requiresSourceImage: false, includesOutputDimensions: true),
        "sdxl_diffusers": Mode(promptStatusLabel: "Prompt:", requiresSourceImage: false, includesOutputDimensions: true),
        "mflux_fill_expand": Mode(promptStatusLabel: "Outfill:", requiresSourceImage: true, includesOutputDimensions: true),
        "mflux_fill_infill": Mode(promptStatusLabel: "Infill:", requiresSourceImage: false, includesOutputDimensions: false),
        "mflux_flux2_klein_create": Mode(promptStatusLabel: "Prompt:", requiresSourceImage: false, includesOutputDimensions: true),
        "mflux_flux2_klein_edit": Mode(promptStatusLabel: "Prompt:", requiresSourceImage: true, includesOutputDimensions: false),
        "mflux_flux2_klein_expand": Mode(promptStatusLabel: "Outfill:", requiresSourceImage: true, includesOutputDimensions: true),
    ]

    static func mode(pipelineID: String) -> Mode {
        modes[pipelineID] ?? Mode(promptStatusLabel: "Prompt:", requiresSourceImage: false, includesOutputDimensions: true)
    }

    static func reportsQuantization(pipelineID: String) -> Bool {
        switch pipelineID {
        case "sana_sprint_600m", "z_image_turbo_sdnq", "sd15_diffusers", "sdxl_diffusers":
            return false
        default:
            return true
        }
    }

    static func jobUsesSourceImage(pipelineID: String, values: [String: Any]) -> Bool {
        let m = mode(pipelineID: pipelineID)
        if m.requiresSourceImage { return true }
        if pipelineID == "mflux_flux2_klein_create" {
            return !ImageGenExifReferences.resolveSourceImagePaths(values).isEmpty
        }
        return false
    }
}
