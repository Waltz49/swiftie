import AppKit
import SwiftUI

/// Active theme registry — port of `theme/theme_service.py`.
@Observable
@MainActor
final class ThemeService {
    private unowned let config: AppConfig
    private var appearanceObserver: NSObjectProtocol?

    private(set) var themeID: String = "dark"
    private(set) var resolvedThemeID: String = "dark"
    private(set) var colors: ThemeColors = .dark

    private var previewSettings: [String: Any]?
    private var snapshotSettings: [String: Any]?

    init(config: AppConfig) {
        self.config = config
        reload()
        startAppearanceObserver()
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

    var customThemes: [String: [String: Any]] {
        Self.mergeCustomThemes(config.rawSettings()["custom_themes"] as? [String: Any])
    }

    var customThemeIDs: [String] {
        customThemes.keys.sorted()
    }

    func reload() {
        let settings = effectiveSettings()
        themeID = (settings["ui_theme"] as? String ?? "dark").lowercased()
        resolvedThemeID = Self.resolveThemeID(themeID, settings: settings)
        let merged = Self.mergedColors(for: resolvedThemeID, settings: settings)
        let browse = Self.effectiveBrowseTransparency(settings: settings, themeID: resolvedThemeID)
        colors = ThemeColors.build(themeID: resolvedThemeID, merged: merged, browse: browse)
    }

    func setThemeID(_ id: String, persist: Bool = true) {
        let normalized = id.lowercased()
        if persist {
            config.setValue(normalized, forKey: "ui_theme")
            if previewSettings != nil {
                previewSettings?["ui_theme"] = normalized
            }
        } else {
            var settings = effectiveSettings()
            settings["ui_theme"] = normalized
            previewSettings = settings
        }
        reload()
    }

    func colorOverridesKey(for themeID: String) -> String {
        ThemeKeys.colorOverridesKey(for: themeID)
    }

    func colorOverrides(for themeID: String) -> [String: Any] {
        let settings = effectiveSettings()
        if let entry = Self.customThemeEntry(settings: settings, themeID: themeID) {
            return entry["colors"] as? [String: Any] ?? [:]
        }
        let key = colorOverridesKey(for: themeID)
        return settings[key] as? [String: Any] ?? [:]
    }

    func mergedColorOverrides(for themeID: String) -> [String: Any] {
        Self.mergedColors(for: themeID, settings: effectiveSettings())
    }

    func setColorOverride(themeID: String, key: String, value: Any, persist: Bool = true) {
        if Self.isCustomThemeID(themeID, settings: effectiveSettings()) {
            setCustomThemeOverride(themeID: themeID, key: key, value: value, persist: persist)
            return
        }
        let storageKey = colorOverridesKey(for: themeID)
        var settings = effectiveSettings()
        var dict = settings[storageKey] as? [String: Any] ?? [:]
        dict[key] = value
        settings[storageKey] = dict
        applySettings(settings, persist: persist)
        reload()
    }

    func resetColorOverrides(for themeID: String, persist: Bool = true) {
        let defaults = ThemeDefaults.defaultsForThemeID(themeID)
        if Self.isCustomThemeID(themeID, settings: effectiveSettings()) {
            var settings = effectiveSettings()
            var custom = settings["custom_themes"] as? [String: Any] ?? [:]
            if var entry = custom[themeID] as? [String: Any] {
                entry["colors"] = defaults
                custom[themeID] = entry
                settings["custom_themes"] = custom
                applySettings(settings, persist: persist)
            }
        } else {
            var settings = effectiveSettings()
            settings[colorOverridesKey(for: themeID)] = defaults
            applySettings(settings, persist: persist)
        }
        reload()
    }

    func browseTransparency(for themeID: String) -> [String: Any] {
        let settings = effectiveSettings()
        if let entry = Self.customThemeEntry(settings: settings, themeID: themeID),
           let browse = entry["browse_transparency"] as? [String: Any] {
            return Self.mergeBrowseTransparency(browse)
        }
        let merged = Self.mergeBrowseTransparencySettings(
            settings["browse_transparency_settings"] as? [String: Any]
        )
        let key = ThemeKeys.browseTransparencyThemeIDs.contains(themeID) ? themeID : "dark"
        return merged[key] as? [String: Any] ?? ThemeDefaults.defaultBrowseTransparencyEntry()
    }

    func setBrowseTransparency(themeID: String, key: String, value: Any, persist: Bool = true) {
        var settings = effectiveSettings()
        if Self.isCustomThemeID(themeID, settings: settings) {
            var custom = settings["custom_themes"] as? [String: Any] ?? [:]
            guard var entry = custom[themeID] as? [String: Any] else { return }
            var browse = entry["browse_transparency"] as? [String: Any]
                ?? ThemeDefaults.defaultBrowseTransparencyEntry()
            browse[key] = value
            entry["browse_transparency"] = browse
            custom[themeID] = entry
            settings["custom_themes"] = custom
        } else {
            var all = Self.mergeBrowseTransparencySettings(
                settings["browse_transparency_settings"] as? [String: Any]
            )
            var entry = all[themeID] as? [String: Any] ?? ThemeDefaults.defaultBrowseTransparencyEntry()
            entry[key] = value
            all[themeID] = entry
            settings["browse_transparency_settings"] = all
        }
        applySettings(settings, persist: persist)
        reload()
    }

    func createCustomTheme(displayName: String, base: String) -> String? {
        let slug = Self.slugify(displayName)
        guard !slug.isEmpty, !ThemeKeys.builtinThemeIDs.contains(slug) else { return nil }
        var settings = effectiveSettings()
        var custom = Self.mergeCustomThemes(settings["custom_themes"] as? [String: Any])
        var finalSlug = slug
        var n = 2
        while custom[finalSlug] != nil {
            finalSlug = "\(slug)_\(n)"
            n += 1
        }
        let baseID = ThemeKeys.editableBuiltinThemeIDs.contains(base) ? base : "dark"
        custom[finalSlug] = [
            "display_name": displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            "base": baseID,
            "colors": ThemeDefaults.defaultsForThemeID(baseID),
            "browse_transparency": ThemeDefaults.defaultBrowseTransparencyEntry(),
        ]
        settings["custom_themes"] = custom
        settings["ui_theme"] = finalSlug
        applySettings(settings, persist: true)
        reload()
        return finalSlug
    }

    func deleteCustomTheme(_ themeID: String) {
        var settings = effectiveSettings()
        var custom = settings["custom_themes"] as? [String: Any] ?? [:]
        custom.removeValue(forKey: themeID)
        settings["custom_themes"] = custom
        if (settings["ui_theme"] as? String)?.lowercased() == themeID.lowercased() {
            settings["ui_theme"] = "dark"
        }
        applySettings(settings, persist: true)
        reload()
    }

    func customThemeDisplayName(_ themeID: String) -> String {
        if let entry = customThemes[themeID] {
            return entry["display_name"] as? String ?? themeID
        }
        return themeID
    }

    func editableThemeID() -> String {
        if ThemeKeys.editableBuiltinThemeIDs.contains(themeID) {
            return themeID
        }
        if ThemeKeys.editableBuiltinThemeIDs.contains(resolvedThemeID) {
            return resolvedThemeID
        }
        if customThemes[themeID] != nil {
            return themeID
        }
        return resolvedThemeID
    }

    func captureSnapshot() {
        let raw = config.rawSettings()
        snapshotSettings = Self.themePersistKeys.reduce(into: [String: Any]()) { result, key in
            if let value = raw[key] {
                result[key] = value
            }
        }
    }

    func restoreSnapshot() {
        guard let saved = snapshotSettings else { return }
        previewSettings = nil
        for key in Self.themePersistKeys {
            if let value = saved[key] {
                config.setValue(value, forKey: key)
            }
        }
        config.saveSettings()
        reload()
        snapshotSettings = nil
    }

    func commitPreview() {
        if let preview = previewSettings {
            for key in Self.themePersistKeys {
                if let value = preview[key] {
                    config.setValue(value, forKey: key)
                }
            }
            config.saveSettings()
            previewSettings = nil
        }
        snapshotSettings = nil
    }

    func discardPreview() {
        previewSettings = nil
        reload()
    }

    func collapseGroupExpanded(_ key: String) -> Bool {
        let groups = config.rawSettings()["theme_settings_groups_expanded"] as? [String: Bool] ?? [:]
        return groups[key] ?? true
    }

    func setCollapseGroupExpanded(_ key: String, expanded: Bool) {
        var groups = config.rawSettings()["theme_settings_groups_expanded"] as? [String: Bool] ?? [:]
        groups[key] = expanded
        config.setValue(groups, forKey: "theme_settings_groups_expanded")
    }

    // MARK: - Private

    private func effectiveSettings() -> [String: Any] {
        previewSettings ?? config.rawSettings()
    }

    private func applySettings(_ settings: [String: Any], persist: Bool) {
        if persist {
            for key in Self.themePersistKeys {
                if let value = settings[key] {
                    config.setValue(value, forKey: key)
                }
            }
            config.saveSettings()
            previewSettings = nil
        } else {
            previewSettings = settings
        }
    }

    private func setCustomThemeOverride(themeID: String, key: String, value: Any, persist: Bool) {
        var settings = effectiveSettings()
        var custom = settings["custom_themes"] as? [String: Any] ?? [:]
        guard var entry = custom[themeID] as? [String: Any] else { return }
        var colors = entry["colors"] as? [String: Any] ?? [:]
        colors[key] = value
        entry["colors"] = colors
        custom[themeID] = entry
        settings["custom_themes"] = custom
        applySettings(settings, persist: persist)
        reload()
    }

    private func startAppearanceObserver() {
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.themeID == "system" {
                    self.reload()
                }
            }
        }
    }

    // MARK: - Static merge helpers

    private static let themePersistKeys: [String] = [
        "ui_theme",
        "user_theme_colors",
        "dark_theme_colors",
        "light_theme_colors",
        "custom_themes",
        "browse_transparency_settings",
        "theme_settings_groups_expanded",
    ]

    static func resolveThemeID(_ uiTheme: String, settings: [String: Any]) -> String {
        let normalized = uiTheme.lowercased()
        if normalized == "system" {
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? "dark" : "light"
        }
        if ThemeKeys.editableBuiltinThemeIDs.contains(normalized) || normalized == "dark" {
            return normalized
        }
        if isCustomThemeID(normalized, settings: settings) {
            return normalized
        }
        return "dark"
    }

    static func isCustomThemeID(_ themeID: String, settings: [String: Any]) -> Bool {
        let custom = mergeCustomThemes(settings["custom_themes"] as? [String: Any])
        return custom[themeID.lowercased()] != nil
    }

    static func customThemeEntry(settings: [String: Any], themeID: String) -> [String: Any]? {
        mergeCustomThemes(settings["custom_themes"] as? [String: Any])[themeID.lowercased()]
    }

    static func mergedColors(for themeID: String, settings: [String: Any]) -> [String: Any] {
        if let entry = customThemeEntry(settings: settings, themeID: themeID) {
            let base = entry["base"] as? String ?? "dark"
            return mergeThemeColors(
                stored: entry["colors"] as? [String: Any],
                defaults: ThemeDefaults.defaultsForThemeID(base)
            )
        }
        let defaults = ThemeDefaults.defaultsForThemeID(themeID)
        let key = ThemeKeys.colorOverridesKey(for: themeID)
        return mergeThemeColors(stored: settings[key] as? [String: Any], defaults: defaults)
    }

    static func mergeThemeColors(stored: [String: Any]?, defaults: [String: Any]) -> [String: Any] {
        var out = defaults
        guard let stored else { return finalizeMergedColors(out) }
        for key in ThemeKeys.userThemeColorKeys {
            if let v = stored[key] as? String, !v.trimmingCharacters(in: .whitespaces).isEmpty {
                out[key] = v.trimmingCharacters(in: .whitespaces)
            }
        }
        mergeBorderWidthIndices(&out, stored: stored)
        mergeViewBorderWidth(&out, stored: stored)
        mergeMutedBlendPercent(&out, stored: stored)
        return finalizeMergedColors(out)
    }

    private static func finalizeMergedColors(_ out: [String: Any]) -> [String: Any] {
        out
    }

    private static func mergeBorderWidthIndices(_ out: inout [String: Any], stored: [String: Any]) {
        for key in ThemeKeys.borderWidthKeys {
            let fallback = out[key] as? Int ?? 1
            out[key] = coerceImageBorderWidth(stored[key], fallback: fallback)
        }
    }

    private static func mergeViewBorderWidth(_ out: inout [String: Any], stored: [String: Any]) {
        let fallback = coerceViewBorderWidth(out["view_border_width_px"], fallback: 2)
        if stored["view_border_width_px"] != nil {
            out["view_border_width_px"] = coerceViewBorderWidth(stored["view_border_width_px"], fallback: fallback)
        } else {
            out["view_border_width_px"] = fallback
        }
    }

    private static func mergeMutedBlendPercent(_ out: inout [String: Any], stored: [String: Any]) {
        var legacyFallback: Int?
        if stored["muted_text_blend_percent"] != nil {
            legacyFallback = coerceMutedBlendPercent(stored["muted_text_blend_percent"], fallback: 50)
        }
        for key in ThemeKeys.mutedBlendKeys {
            let defaultFB = legacyFallback ?? 50
            let fb = coerceMutedBlendPercent(out[key], fallback: defaultFB)
            if stored[key] != nil {
                out[key] = coerceMutedBlendPercent(stored[key], fallback: fb)
            } else {
                out[key] = fb
            }
        }
    }

    private static func coerceImageBorderWidth(_ stored: Any?, fallback: Int) -> Int {
        if let v = stored as? Int, (0...ThemeKeys.maxImageBorderWidthPx).contains(v) { return v }
        if let s = stored as? String, let v = Int(s.trimmingCharacters(in: .whitespaces)),
           (0...ThemeKeys.maxImageBorderWidthPx).contains(v) { return v }
        return max(0, min(ThemeKeys.maxImageBorderWidthPx, fallback))
    }

    private static func coerceViewBorderWidth(_ stored: Any?, fallback: Int) -> Int {
        let lo = ThemeKeys.minViewChromeBorderWidthPx
        let hi = ThemeKeys.maxViewChromeBorderWidthPx
        if let v = stored as? Int, (lo...hi).contains(v) { return v }
        if let s = stored as? String, let v = Int(s.trimmingCharacters(in: .whitespaces)),
           (lo...hi).contains(v) { return v }
        return max(lo, min(hi, fallback))
    }

    private static func coerceMutedBlendPercent(_ stored: Any?, fallback: Int) -> Int {
        let lo = ThemeKeys.mutedBlendMinPercent
        let hi = ThemeKeys.mutedBlendMaxPercent
        if let v = stored as? Int, (lo...hi).contains(v) { return v }
        if let s = stored as? String, let v = Int(s.trimmingCharacters(in: .whitespaces)),
           (lo...hi).contains(v) { return v }
        return max(lo, min(hi, fallback))
    }

    static func mergeCustomThemes(_ raw: [String: Any]?) -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        guard let raw else { return out }
        for (slug, ent) in raw {
            guard !slug.isEmpty, !ThemeKeys.builtinThemeIDs.contains(slug),
                  let entry = ent as? [String: Any] else { continue }
            let base = (entry["base"] as? String ?? "dark").lowercased()
            let resolvedBase = ThemeKeys.editableBuiltinThemeIDs.contains(base) ? base : "dark"
            let displayName = (entry["display_name"] as? String ?? slug).trimmingCharacters(in: .whitespaces)
            let colors = mergeThemeColors(
                stored: entry["colors"] as? [String: Any],
                defaults: ThemeDefaults.defaultsForThemeID(resolvedBase)
            )
            let browse = mergeBrowseTransparency(entry["browse_transparency"] as? [String: Any])
            out[slug] = [
                "display_name": displayName.isEmpty ? slug : displayName,
                "base": resolvedBase,
                "colors": colors,
                "browse_transparency": browse,
            ]
        }
        return out
    }

    static func mergeBrowseTransparencySettings(_ raw: [String: Any]?) -> [String: Any] {
        var base = ThemeDefaults.defaultBrowseTransparencySettings()
        guard let raw else { return base }
        for tid in ThemeKeys.browseTransparencyThemeIDs {
            if let ent = raw[tid] as? [String: Any] {
                base[tid] = mergeBrowseTransparency(ent)
            }
        }
        return base
    }

    static func mergeBrowseTransparency(_ raw: [String: Any]?) -> [String: Any] {
        var out = ThemeDefaults.defaultBrowseTransparencyEntry()
        guard let raw else { return out }
        if let tc = raw["transparency_color"] as? [Int], tc.count >= 3 {
            out["transparency_color"] = [tc[0], tc[1], tc[2]]
        } else if let tc = raw["transparency_color"] as? [Any], tc.count >= 3 {
            out["transparency_color"] = tc.prefix(3).compactMap { ($0 as? NSNumber)?.intValue ?? $0 as? Int }
        }
        if let useDiamonds = raw["use_diamonds"] as? Bool {
            out["use_diamonds"] = useDiamonds
        }
        if let bbc = raw["browse_border_color"] as? [Int], bbc.count >= 3 {
            out["browse_border_color"] = [bbc[0], bbc[1], bbc[2]]
        } else if let bbc = raw["browse_border_color"] as? [Any], bbc.count >= 3 {
            out["browse_border_color"] = bbc.prefix(3).compactMap { ($0 as? NSNumber)?.intValue ?? $0 as? Int }
        }
        return out
    }

    static func effectiveBrowseTransparency(settings: [String: Any], themeID: String) -> [String: Any] {
        if let entry = customThemeEntry(settings: settings, themeID: themeID),
           let browse = entry["browse_transparency"] as? [String: Any] {
            return mergeBrowseTransparency(browse)
        }
        let merged = mergeBrowseTransparencySettings(settings["browse_transparency_settings"] as? [String: Any])
        let key = ThemeKeys.browseTransparencyThemeIDs.contains(themeID) ? themeID : "dark"
        return merged[key] as? [String: Any] ?? ThemeDefaults.defaultBrowseTransparencyEntry()
    }

    private static func slugify(_ name: String) -> String {
        let lowered = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            if scalar == " " || scalar == "-" || scalar == "_" { return "_" }
            return "_"
        }
        var slug = String(allowed)
        while slug.contains("__") { slug = slug.replacingOccurrences(of: "__", with: "_") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return slug
    }
}
