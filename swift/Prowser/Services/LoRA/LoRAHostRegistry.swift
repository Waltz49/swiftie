import Foundation

enum LoRAHostRegistry {
    static let flux1T2I = "flux1_t2i"
    static let flux1Fill = "flux1_fill"
    static let flux2Klein = "flux2_klein"
    static let sd15 = "sd15"
    static let sdxl = "sdxl"
    static let zImageTurbo = "z_image_turbo"

    static let hostOrder: [String] = [
        flux1T2I, flux1Fill, flux2Klein, zImageTurbo, sd15, sdxl,
    ]

    private static let pipelineToHost: [String: String] = [
        "flux_schnell_mflux_play": flux1T2I,
        "mflux_fill_expand": flux1Fill,
        "mflux_fill_infill": flux1Fill,
        "mflux_flux2_klein_create": flux2Klein,
        "mflux_flux2_klein_edit": flux2Klein,
        "mflux_flux2_klein_expand": flux2Klein,
        "mflux_z_image_turbo": zImageTurbo,
        "sd15_diffusers": sd15,
        "sdxl_diffusers": sdxl,
    ]

    static func hostForPipeline(_ pipelineID: String) -> String? {
        pipelineToHost[pipelineID.trimmingCharacters(in: .whitespacesAndNewlines)]
    }
}
