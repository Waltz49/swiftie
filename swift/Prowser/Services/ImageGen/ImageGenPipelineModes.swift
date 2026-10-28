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
    private static let mfluxFlowMatchMinSteps = 2

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

    /// Settings values may be `Bool`, `NSNumber` (JSON/plist), or legacy strings.
    static func boolFromSettingsValue(_ value: Any?) -> Bool {
        switch value {
        case let flag as Bool:
            return flag
        case let number as NSNumber:
            return number.boolValue
        case let number as Int:
            return number != 0
        case let text as String:
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            default:
                return false
            }
        default:
            return false
        }
    }

    static func showProgressiveImages(in imagegen: [String: Any]) -> Bool {
        boolFromSettingsValue(imagegen["show_progressive_images"])
    }

    static func showProgressiveImages(config: AppConfig) -> Bool {
        let imagegen = config.rawSettings()["imagegen"] as? [String: Any] ?? [:]
        return showProgressiveImages(in: imagegen)
    }

    static func finalizeRunValues(pipelineID: String, values: [String: Any], config: AppConfig) -> [String: Any] {
        var out = values
        guard let mode = mode(pipelineID: pipelineID) else { return out }
        var steps = intValue(out["steps"]) ?? mode.stepsDefault
        steps = max(mode.stepsMin, min(mode.stepsMax, steps))
        if pipelineID.hasPrefix("mflux_flux2_klein") {
            steps = max(mfluxFlowMatchMinSteps, steps)
        } else if pipelineID.hasPrefix("flux_schnell") || pipelineID.hasPrefix("mflux_") {
            steps = max(mfluxMinSteps, steps)
        }
        out["steps"] = steps
        if mode.supportsProgressiveImages {
            out["show_progressive_images"] = showProgressiveImages(config: config)
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

    /// Port of ``effective_pipeline_id_for_values``.
    static func effectivePipelineIDForValues(pipelineID: String, values: [String: Any]) -> String {
        if pipelineID == "mflux_flux2_klein_create",
           !ImageGenExifReferences.resolveSourceImagePaths(values).isEmpty {
            return "mflux_flux2_klein_edit"
        }
        return pipelineID
    }

    /// Output dimensions shown on job cards (port of ``generation_status_display_size``).
    static func generationStatusDisplaySize(
        plugin: ImageGenPluginDescriptor,
        values: [String: Any],
        payload: [String: Any]?,
        settings: [String: Any]
    ) -> (width: Int, height: Int)? {
        var merged = values
        if let payload {
            for (key, value) in payload {
                merged[key] = value
            }
        }
        let pluginMax = ImageGenDimLimits.effectiveMaxGenerationDimension(
            pluginMax: ImageGenPluginMetadata.maxGenerationDimension(pluginID: plugin.pluginID),
            settings: settings
        )
        let maxSide = intValue(merged["max_generation_dimension"]) ?? pluginMax
        let pipelineID = effectivePipelineIDForValues(pipelineID: plugin.pipelineID, values: merged)

        if pipelineID == "mflux_flux2_klein_edit" {
            if boolFromSettingsValue(merged["use_custom_size"]) {
                guard let w = intValue(merged["width"]), let h = intValue(merged["height"]), w > 0, h > 0 else {
                    return nil
                }
                let fitted = ImageGenInfillMath.fitEditOutputDims(width: w, height: h, maxSide: maxSide)
                return (fitted.width, fitted.height)
            }
            let paths = ImageGenExifReferences.resolveSourceImagePaths(merged)
            guard let path = paths.first,
                  FileManager.default.fileExists(atPath: path),
                  let size = ImageRecognitionImageLoader.orientedPixelSize(path: path) else {
                return nil
            }
            let fitted = ImageGenInfillMath.fitEditOutputDims(
                width: size.width,
                height: size.height,
                maxSide: maxSide
            )
            return (fitted.width, fitted.height)
        }

        if pipelineID == "mflux_fill_infill" {
            let basePath = (merged["pixelmator_base_path"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !basePath.isEmpty, FileManager.default.fileExists(atPath: basePath),
                  let size = ImageRecognitionImageLoader.orientedPixelSize(path: basePath) else {
                return nil
            }
            return ImageGenDimMath.alignDimsForPipeline(
                pipelineID: "flux_schnell_mflux_play",
                width: size.width,
                height: size.height,
                effectiveMaxSide: maxSide
            )
        }

        guard mode(pipelineID: pipelineID)?.includesOutputDimensions == true else { return nil }

        var w: Int?
        var h: Int?
        if let payload {
            if let pw = intValue(payload["width"]), let ph = intValue(payload["height"]), pw > 0, ph > 0 {
                w = pw
                h = ph
            }
        }
        if w == nil || h == nil || (w ?? 0) <= 0 || (h ?? 0) <= 0 {
            guard let mw = intValue(merged["width"]), let mh = intValue(merged["height"]), mw > 0, mh > 0 else {
                return nil
            }
            return ImageGenDimMath.alignDimsForPipeline(
                pipelineID: pipelineID,
                width: mw,
                height: mh,
                effectiveMaxSide: maxSide
            )
        }
        guard let w, let h else { return nil }
        if pipelineID == "mflux_fill_expand" {
            return ImageGenOutpaintMask.clampOutpaintDims(width: w, height: h, maxSide: maxSide)
        }
        return (w, h)
    }
}
