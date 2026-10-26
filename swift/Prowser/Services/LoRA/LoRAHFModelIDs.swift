import Foundation

/// Canonical Hugging Face model ids (port of `hf_model_ids.py`).
enum LoRAHFModelIDs {
    static let flux1Schnell = "black-forest-labs/FLUX.1-schnell"
    static let flux1Dev = "black-forest-labs/FLUX.1-dev"
    static let flux1FillDev = "black-forest-labs/FLUX.1-Fill-dev"
    static let flux2Klein4B = "black-forest-labs/FLUX.2-klein-4B"
    static let flux2Klein9B = "black-forest-labs/FLUX.2-klein-9B"
    static let flux2Klein9BKV = "black-forest-labs/FLUX.2-klein-9b-kv"
    static let sceneworksFlux2Klein9BKVMLX = "SceneWorks/flux2-klein-9b-kv-mlx"

    static let sd15BaseV15 = "stable-diffusion-v1-5/stable-diffusion-v1-5"
    static let realisticVisionV4NoVAE = "SG161222/Realistic_Vision_V4.0_noVAE"
    static let anythingFurry = "stablediffusionapi/anythingfurry"
    static let sdxlBase10 = "stabilityai/stable-diffusion-xl-base-1.0"
    static let zImageTurboMflux4Bit = "filipstrand/Z-Image-Turbo-mflux-4bit"
    static let zImageTurbo = "Tongyi-MAI/Z-Image-Turbo"

    static let sd15LoraModelKeys: [String] = [sd15BaseV15, realisticVisionV4NoVAE, anythingFurry]
    static let sdxlLoraModelKeys: [String] = [sdxlBase10]

    static let probeModelOrder: [String] = [
        flux1Schnell, flux1Dev, flux1FillDev,
        flux2Klein4B, flux2Klein9B, flux2Klein9BKV, sceneworksFlux2Klein9BKVMLX,
        zImageTurboMflux4Bit, zImageTurbo,
        sd15BaseV15,
        realisticVisionV4NoVAE, anythingFurry,
        sdxlBase10,
    ]

    static let legacyZMfluxHFIDs: Set<String> = [
        "Disty0/Z-Image-Turbo-SDNQ-int8",
        "Tongyi-MAI/Z-Image-Turbo-mflux",
    ]

    static func displayName(for modelKey: String) -> String {
        let map: [String: String] = [
            flux1Schnell: "FLUX.1 Schnell",
            flux1Dev: "FLUX.1 Dev",
            flux1FillDev: "FLUX.1 Fill",
            flux2Klein4B: "FLUX.2 Klein 4B",
            flux2Klein9B: "FLUX.2 Klein 9B",
            flux2Klein9BKV: "FLUX.2 Klein 9B KV",
            sceneworksFlux2Klein9BKVMLX: "FLUX.2 Klein 9B KV MLX",
            sd15BaseV15: "SD 1.5 Base",
            realisticVisionV4NoVAE: "Realistic Vision V4.0",
            anythingFurry: "Anything Furry",
            sdxlBase10: "SDXL 1.0 Base",
            zImageTurboMflux4Bit: "Z-Image Turbo (4-bit)",
            zImageTurbo: "Z-Image Turbo",
        ]
        return map[modelKey] ?? modelKey
    }
}
