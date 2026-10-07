import Foundation

/// Port of `imagegen_plugins/image_gen_dim_limits.py` constants for settings UI.
enum ImageGenDimLimits {
    static let maxGenerationDimensionDefault = 1024
    static let maxGenerationDimensionMin = 256
    static let maxGenerationDimensionCeiling = 2048
    static let maxGenerationDimensionStep = 16

    static let seriesCooldownSecondsMin = 0
    static let seriesCooldownSecondsMax = 120
    static let jobCooldownSecondsDefault = 0
    static let interCopyCooldownSecondsDefault = 23

    static let outputFormats = ["png", "webp"]

    static func alignGenerationDimension(_ value: Int) -> Int {
        let step = maxGenerationDimensionStep
        var v = max(maxGenerationDimensionMin, min(maxGenerationDimensionCeiling, value))
        v -= v % step
        return max(maxGenerationDimensionMin, v)
    }

    static func dimensionFromSliderIndex(_ index: Int) -> Int {
        alignGenerationDimension(maxGenerationDimensionMin + index * maxGenerationDimensionStep)
    }

    static func sliderIndexFromDimension(_ dimension: Int) -> Int {
        let aligned = alignGenerationDimension(dimension)
        return (aligned - maxGenerationDimensionMin) / maxGenerationDimensionStep
    }

    static var sliderMaxIndex: Int {
        (maxGenerationDimensionCeiling - maxGenerationDimensionMin) / maxGenerationDimensionStep
    }

    static func clampCooldownSeconds(_ raw: Any?, default defaultValue: Int) -> Int {
        let value: Int
        if let intValue = raw as? Int {
            value = intValue
        } else if let number = raw as? NSNumber {
            value = number.intValue
        } else if let string = raw as? String, let intValue = Int(string) {
            value = intValue
        } else {
            value = defaultValue
        }
        return max(seriesCooldownSecondsMin, min(seriesCooldownSecondsMax, value))
    }

    /// Port of ``app_job_cooldown_seconds`` — wait after one queued job before the next.
    static func appJobCooldownSeconds(settings: [String: Any]) -> Int {
        clampCooldownSeconds(
            settings["imagegen_job_cooldown_seconds"],
            default: jobCooldownSecondsDefault
        )
    }

    /// Port of ``app_inter_copy_cooldown_seconds`` — wait between copies in a series.
    static func appInterCopyCooldownSeconds(settings: [String: Any]) -> Int {
        let raw: Any?
        if settings["imagegen_inter_copy_cooldown_seconds"] != nil {
            raw = settings["imagegen_inter_copy_cooldown_seconds"]
        } else {
            raw = settings["imagegen_series_cooldown_seconds"]
        }
        return clampCooldownSeconds(raw, default: interCopyCooldownSecondsDefault)
    }

    /// Port of ``app_max_generation_dimension``.
    static func appMaxGenerationDimension(settings: [String: Any]) -> Int {
        let raw = settings["imagegen_max_generation_dimension"]
        let value: Int
        if let intValue = raw as? Int {
            value = intValue
        } else if let number = raw as? NSNumber {
            value = number.intValue
        } else if let string = raw as? String, let intValue = Int(string) {
            value = intValue
        } else {
            value = maxGenerationDimensionDefault
        }
        return alignGenerationDimension(value)
    }

    static func effectiveMaxGenerationDimension(pluginMax: Int, settings: [String: Any]) -> Int {
        min(alignGenerationDimension(pluginMax), appMaxGenerationDimension(settings: settings))
    }

    static func normalizedOutputFormat(_ raw: Any?) -> String {
        let fmt = (raw as? String ?? "png").trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".", with: "")
            .lowercased()
        return outputFormats.contains(fmt) ? fmt : "png"
    }

    static func outputExtension(from settings: [String: Any]) -> String {
        ".\(normalizedOutputFormat(settings["imagegen_output_format"]))"
    }
}
