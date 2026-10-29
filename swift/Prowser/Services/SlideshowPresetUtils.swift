import Foundation

/// Port of `slideshow/slideshow_preset_utils.py`.
enum SlideshowPresetUtils {
    static let presetDefaults: [String: [String: Any]] = [
        "0": [
            "name": "Slow",
            "rate": 3500,
            "transition_speed": 2000,
            "max_rotation": 90,
            "overlap_delay": 0,
            "direction": "random",
        ],
        "9": [
            "name": "Fast",
            "rate": 3500,
            "transition_speed": 1200,
            "max_rotation": 0,
            "overlap_delay": 0,
            "direction": "none",
        ],
    ]

    static func normalizePreset(_ preset: Any?, key: String) -> [String: Any] {
        let defaults = presetDefaults[key] ?? presetDefaults["0"]!
        guard let preset = preset as? [String: Any] else { return defaults }
        var merged = defaults
        if let name = preset["name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            merged["name"] = name.trimmingCharacters(in: .whitespaces)
        }
        for field in ["rate", "transition_speed", "max_rotation", "overlap_delay"] {
            if let value = preset[field] as? NSNumber {
                merged[field] = value.intValue
            }
        }
        if let direction = preset["direction"] as? String, Set(validDirections).contains(direction) {
            merged["direction"] = direction
        }
        return merged
    }

    static func preset(from settings: [String: Any], key: String) -> [String: Any] {
        let configKey = key == "9" ? "slideshow_preset_9" : "slideshow_preset_0"
        return normalizePreset(settings[configKey], key: key)
    }

    /// Startup slideshow timing/direction (keys 1–8 and Settings → startup defaults); preset name is excluded.
    static func startupTimingFields(from settings: [String: Any]) -> [String: Any] {
        let transitionSpeed = (settings["slideshow_transition_speed"] as? NSNumber)?.intValue ?? 1300
        let overlapPercentValue: Int
        if let stored = settings["slideshow_overlap_percent"] as? Int {
            overlapPercentValue = stored
        } else {
            let delay = (settings["slideshow_overlap_delay"] as? NSNumber)?.intValue ?? 0
            overlapPercentValue = overlapPercent(overlapDelay: delay, transitionSpeed: transitionSpeed)
        }
        let overlapDelayValue = overlapDelay(overlapPercent: overlapPercentValue, transitionSpeed: transitionSpeed)
        let direction = settings["slideshow_direction"] as? String ?? "right"
        return [
            "rate": (settings["slideshow_rate"] as? NSNumber)?.intValue ?? 5000,
            "transition_speed": transitionSpeed,
            "max_rotation": (settings["slideshow_max_rotation"] as? NSNumber)?.intValue ?? 0,
            "overlap_delay": overlapDelayValue,
            "direction": Set(validDirections).contains(direction) ? direction : "right",
        ]
    }

    /// Runtime slideshow playback only; does not modify persisted settings.
    static func effectiveTransitionSpeedMs(transitionSpeedMs: Int, slideRateMs: Int) -> Int {
        let transition = max(0, transitionSpeedMs)
        guard slideRateMs > 0 else { return transition }
        return min(transition, slideRateMs)
    }

    static func overlapPercent(overlapDelay: Int, transitionSpeed: Int) -> Int {
        guard transitionSpeed > 0 else { return 100 }
        return Int(100 - (Double(overlapDelay) / Double(transitionSpeed) * 100))
    }

    static func overlapDelay(overlapPercent: Int, transitionSpeed: Int) -> Int {
        guard transitionSpeed > 0 else { return 0 }
        return Int((100 - overlapPercent) * transitionSpeed / 100)
    }

    static let validDirections = ["right", "left", "top", "bottom", "random", "none"]

    static func statusMessage(for preset: [String: Any]) -> String {
        let overlap = overlapPercent(
            overlapDelay: preset["overlap_delay"] as? Int ?? 0,
            transitionSpeed: preset["transition_speed"] as? Int ?? 1300
        )
        let name = preset["name"] as? String ?? "Preset"
        return "\(name): \(preset["rate"] ?? 0)ms slides, \(preset["transition_speed"] ?? 0)ms transitions, \(preset["max_rotation"] ?? 0)° rotation, \(overlap)% overlap, direction: \(preset["direction"] ?? "right")"
    }
}
