import AppKit
import SwiftUI

/// Active theme registry — port of `theme/theme_service.py` (phase 1).
@Observable
@MainActor
final class ThemeService {
    private unowned let config: AppConfig

    private(set) var themeID: String = "dark"
    private(set) var resolvedThemeID: String = "dark"
    private(set) var colors: ThemeColors = .dark

    init(config: AppConfig) {
        self.config = config
        reload()
    }

    var preferredColorScheme: ColorScheme? {
        switch resolvedThemeID {
        case "light": return .light
        case "dark": return .dark
        default:
            if themeID == "system" {
                return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? .dark : .light
            }
            return .dark
        }
    }

    func reload() {
        themeID = (config.rawSettings()["ui_theme"] as? String ?? "dark").lowercased()
        resolvedThemeID = Self.resolveThemeID(themeID, settings: config.rawSettings())
        colors = Self.buildColors(themeID: resolvedThemeID, settings: config.rawSettings())
    }

    func setThemeID(_ id: String) {
        config.setValue(id, forKey: "ui_theme")
        reload()
    }

    func colorOverridesKey(for themeID: String) -> String {
        switch themeID {
        case "light": return "light_theme_colors"
        case "dark": return "dark_theme_colors"
        case "user": return "user_theme_colors"
        default: return "user_theme_colors"
        }
    }

    func colorOverrides(for themeID: String) -> [String: Any] {
        let key = colorOverridesKey(for: themeID)
        return config.rawSettings()[key] as? [String: Any] ?? [:]
    }

    func setColorOverride(themeID: String, key: String, hex: String) {
        let storageKey = colorOverridesKey(for: themeID)
        var dict = config.rawSettings()[storageKey] as? [String: Any] ?? [:]
        dict[key] = hex
        config.setValue(dict, forKey: storageKey)
        reload()
    }

    func resetColorOverrides(for themeID: String) {
        let defaults: [String: Any]
        switch themeID {
        case "light": defaults = ThemeDefaults.lightThemeColors()
        case "dark": defaults = ThemeDefaults.darkThemeColors()
        default: defaults = ThemeDefaults.userThemeColors()
        }
        config.setValue(defaults, forKey: colorOverridesKey(for: themeID))
        reload()
    }

    static func resolveThemeID(_ uiTheme: String, settings: [String: Any]) -> String {
        let normalized = uiTheme.lowercased()
        if normalized == "system" {
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? "dark" : "light"
        }
        if normalized == "light" || normalized == "dark" || normalized == "user" {
            return normalized
        }
        if let custom = settings["custom_themes"] as? [String: Any], custom[normalized] != nil {
            return normalized
        }
        return "dark"
    }

    private static func buildColors(themeID: String, settings: [String: Any]) -> ThemeColors {
        let base: ThemeColors
        let overrides: [String: Any]

        switch themeID {
        case "light":
            base = .light
            overrides = mergeOverrides(
                ThemeDefaults.lightThemeColors(),
                settings["light_theme_colors"] as? [String: Any]
            )
        case "user":
            base = .dark
            overrides = mergeOverrides(
                ThemeDefaults.userThemeColors(),
                settings["user_theme_colors"] as? [String: Any]
            )
        default:
            if let custom = settings["custom_themes"] as? [String: Any],
               let entry = custom[themeID] as? [String: Any],
               let customColors = entry["colors"] as? [String: Any] {
                base = .dark
                overrides = customColors
            } else {
                base = .dark
                overrides = mergeOverrides(
                    ThemeDefaults.darkThemeColors(),
                    settings["dark_theme_colors"] as? [String: Any]
                )
            }
        }
        return ThemeColors.fromDictionary(overrides, fallback: base)
    }

    private static func mergeOverrides(_ defaults: [String: Any], _ saved: [String: Any]?) -> [String: Any] {
        var merged = defaults
        guard let saved else { return merged }
        for (key, value) in saved { merged[key] = value }
        return merged
    }
}
