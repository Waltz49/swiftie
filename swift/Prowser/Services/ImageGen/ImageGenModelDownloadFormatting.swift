import Foundation

/// Shared manage-models formatting (nonisolated for catalog entries).
enum ImageGenModelDownloadFormatting {
    private static let functionLabels: [String: String] = [
        "create": "Create",
        "edit": "Edit",
        "expand": "Expand",
        "infill": "Infill",
    ]

    private static let sizeEstimateBytes: [String: Int] = [
        LoRAHFModelIDs.flux1Schnell: 33_751_852_192,
        LoRAHFModelIDs.flux1Dev: 33_752_765_526,
        LoRAHFModelIDs.flux1FillDev: 33_831_976_058,
        LoRAHFModelIDs.flux2Klein4B: 23_748_001_493,
        LoRAHFModelIDs.flux2Klein9B: 52_887_747_363,
        LoRAHFModelIDs.flux2Klein9BKV: 52_886_250_544,
        LoRAHFModelIDs.sceneworksFlux2Klein9BKVMLX: 22_000_000_000,
        "Efficient-Large-Model/Sana_Sprint_0.6B_1024px_diffusers": 7_703_533_162,
        "Efficient-Large-Model/Sana_Sprint_600M_1024px_diffusers": 7_703_533_162,
        LoRAHFModelIDs.zImageTurboMflux4Bit: 5_900_000_000,
        LoRAHFModelIDs.zImageTurbo: 12_000_000_000,
        LoRAHFModelIDs.anythingFurry: 4_100_000_000,
        LoRAHFModelIDs.realisticVisionV4NoVAE: 4_265_000_000,
        LoRAHFModelIDs.sd15BaseV15: 4_400_000_000,
        "stabilityai/sd-vae-ft-mse": 334_000_000,
        LoRAHFModelIDs.sdxlBase10: 14_000_000_000,
    ]

    static func functionLabel(_ function: String) -> String {
        functionLabels[function] ?? function.capitalized
    }

    static func sizeEstimateBytes(for repoID: String) -> Int {
        sizeEstimateBytes[repoID] ?? 0
    }

    static func formatDownloadSizeEstimate(repoID: String, bytes: Int) -> String {
        let n = bytes > 0 ? bytes : (sizeEstimateBytes[repoID] ?? 0)
        if n <= 0 { return "unknown size" }
        let gb = Double(n) / 1_000_000_000
        if gb >= 10 { return String(format: "~%.0f GB", gb) }
        return String(format: "~%.1f GB", gb)
    }
}
