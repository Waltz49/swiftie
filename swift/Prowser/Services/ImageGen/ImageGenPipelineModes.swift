import Foundation

@MainActor
enum ImageGenPipelineModes {
    struct Mode {
        let stepsMin: Int
        let stepsMax: Int
        let stepsDefault: Int
        let supportsProgressiveImages: Bool
        let supportsLowRAM: Bool
        let includesOutputDimensions: Bool
    }

    private static let mfluxMinSteps = 4

    private static let modes: [String: Mode] = [
        "flux_schnell_mflux_play": Mode(stepsMin: 4, stepsMax: 30, stepsDefault: 4, supportsProgressiveImages: true, supportsLowRAM: true, includesOutputDimensions: true),
        "sana_sprint_600m": Mode(stepsMin: 1, stepsMax: 50, stepsDefault: 2, supportsProgressiveImages: false, supportsLowRAM: false, includesOutputDimensions: true),
        "z_image_turbo_sdnq": Mode(stepsMin: 1, stepsMax: 20, stepsDefault: 9, supportsProgressiveImages: false, supportsLowRAM: false, includesOutputDimensions: true),
        "mflux_z_image_turbo": Mode(stepsMin: 1, stepsMax: 20, stepsDefault: 9, supportsProgressiveImages: true, supportsLowRAM: true, includesOutputDimensions: true),
        "sd15_diffusers": Mode(stepsMin: 1, stepsMax: 50, stepsDefault: 25, supportsProgressiveImages: true, supportsLowRAM: false, includesOutputDimensions: true),
        "sdxl_diffusers": Mode(stepsMin: 1, stepsMax: 50, stepsDefault: 30, supportsProgressiveImages: true, supportsLowRAM: false, includesOutputDimensions: true),
        "mflux_fill_expand": Mode(stepsMin: 4, stepsMax: 30, stepsDefault: 20, supportsProgressiveImages: true, supportsLowRAM: true, includesOutputDimensions: true),
        "mflux_fill_infill": Mode(stepsMin: 4, stepsMax: 30, stepsDefault: 20, supportsProgressiveImages: true, supportsLowRAM: true, includesOutputDimensions: false),
        "mflux_flux2_klein_create": Mode(stepsMin: 1, stepsMax: 12, stepsDefault: 4, supportsProgressiveImages: true, supportsLowRAM: true, includesOutputDimensions: true),
        "mflux_flux2_klein_edit": Mode(stepsMin: 1, stepsMax: 12, stepsDefault: 4, supportsProgressiveImages: true, supportsLowRAM: true, includesOutputDimensions: false),
        "mflux_flux2_klein_expand": Mode(stepsMin: 1, stepsMax: 12, stepsDefault: 4, supportsProgressiveImages: true, supportsLowRAM: true, includesOutputDimensions: true),
    ]

    static func mode(pipelineID: String) -> Mode? {
        modes[pipelineID]
    }

    static func finalizeRunValues(pipelineID: String, values: [String: Any], config: AppConfig) -> [String: Any] {
        var out = values
        guard let mode = mode(pipelineID: pipelineID) else { return out }
        var steps = intValue(out["steps"]) ?? mode.stepsDefault
        steps = max(mode.stepsMin, min(mode.stepsMax, steps))
        if pipelineID.hasPrefix("flux_schnell") || pipelineID.hasPrefix("mflux_") {
            steps = max(mfluxMinSteps, steps)
        }
        out["steps"] = steps
        if mode.supportsProgressiveImages {
            let imagegen = config.rawSettings()["imagegen"] as? [String: Any] ?? [:]
            out["show_progressive_images"] = imagegen["show_progressive_images"] as? Bool ?? false
        }
        if mode.supportsLowRAM {
            out["low_ram"] = config.bool(forKey: "imagegen_low_ram", default: true)
        } else {
            out.removeValue(forKey: "low_ram")
        }
        return out
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }
}
