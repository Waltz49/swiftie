import SwiftUI

/// Resolved theme palette for SwiftUI and AppKit surfaces.
struct ThemeColors: Equatable {
    var themeID: String

    var background: Color
    var text: Color

    var dialogBackground: Color
    var dialogText: Color
    var dialogInputBackground: Color
    var dialogMutedText: Color

    var sidebarBackground: Color
    var sidebarText: Color
    var sidebarMutedText: Color
    var sidebarHeaderBackground: Color
    var sidebarHeaderBorder: Color
    var sidebarHeaderText: Color
    var sidebarHeaderFocusBackground: Color

    var statusBarBackground: Color
    var statusBarText: Color
    var statusBarMutedText: Color

    var defaultBorder: Color
    var splitterHandleHover: Color
    var splitterHandlePressed: Color
    var viewBorderWidthPx: Int

    var buttonBgDefault: Color
    var buttonTextDefault: Color
    var buttonBorderDefault: Color
    var buttonBgHover: Color
    var buttonTextHover: Color
    var buttonBorderHover: Color

    var thumbnailGridBackground: Color
    var thumbnailText: Color
    var defaultImageBorder: Color
    var defaultImageBackground: Color
    var defaultImageBorderWidth: Int
    var currentImageBorder: Color
    var currentImageBackground: Color
    var currentImageBorderWidth: Int
    var multiselectBorder: Color
    var multiselectBackground: Color
    var multiselectBorderWidth: Int

    var thumbnailEmptyFilterButtonBackground: Color
    var thumbnailEmptyFilterButtonBackgroundHover: Color
    var thumbnailEmptyFilterButtonBorder: Color
    var thumbnailEmptyFilterButtonBorderHover: Color
    var thumbnailEmptyFilterButtonTextHover: Color
    var thumbnailFilenameOverlay: Color

    var browseTransparencyColor: Color
    var browseUseCheckerboard: Bool
    var browseBorderColor: Color

    var jobQueueCellBackground: Color
    var jobQueueRunningCellBackground: Color
    var jobQueueMutedText: Color
    var jobQueueActionBarBackground: Color
    var jobQueueSelectionBorder: Color
    var progressBarBackground: Color
    var progressBarBorder: Color
    var progressBarText: Color
    var progressBarFill: Color

    var dialogMutedBlendPercent: Int
    var sidebarMutedBlendPercent: Int
    var statusBarMutedBlendPercent: Int

    static let dark = ThemeColors.build(themeID: "dark", merged: ThemeDefaults.darkThemeColors(), browse: ThemeDefaults.defaultBrowseTransparencyEntry())

    static let light = ThemeColors.build(themeID: "light", merged: ThemeDefaults.lightThemeColors(), browse: ThemeDefaults.defaultBrowseTransparencyEntry())

    static func fromDictionary(_ dict: [String: Any], themeID: String, browse: [String: Any]) -> ThemeColors {
        let defaults = ThemeDefaults.defaultsForThemeID(themeID)
        var merged = defaults
        for (key, value) in dict { merged[key] = value }
        return build(themeID: themeID, merged: merged, browse: browse)
    }

    static func build(themeID: String, merged: [String: Any], browse: [String: Any]) -> ThemeColors {
        func hex(_ key: String, _ fallback: String) -> String {
            if let raw = merged[key] as? String, !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                return raw.trimmingCharacters(in: .whitespaces)
            }
            return fallback
        }
        func resolvedColor(_ key: String, _ defaultHex: String) -> Color {
            Color(hex: hex(key, defaultHex)) ?? Color(hex: defaultHex) ?? .gray
        }
        func rgbaColor(_ key: String, _ fallback: Color) -> Color {
            if let raw = merged[key] as? String {
                return Color(rgbaCSV: raw) ?? fallback
            }
            return fallback
        }
        func intValue(_ key: String, fallback: Int, min: Int, max: Int) -> Int {
            if let v = merged[key] as? Int { return Swift.max(min, Swift.min(max, v)) }
            if let s = merged[key] as? String, let v = Int(s.trimmingCharacters(in: .whitespaces)) {
                return Swift.max(min, Swift.min(max, v))
            }
            return Swift.max(min, Swift.min(max, fallback))
        }

        let darkFallback = ThemeDefaults.darkThemeColors()
        let textHex = hex("text_color_hex", "#b6b6b6")
        let bgHex = hex("default_background_color_hex", "#000000")
        let borderHex = hex("default_border_color_hex", "#606060")
        let dialogBgHex = hex("dialog_background_hex", "#2a2a2a")
        let dialogTextHex = hex("dialog_text_color_hex", "#b6b6b6")
        let sidebarBgHex = hex("sidebar_background_color_hex", bgHex)
        let sidebarTextHex = hex("sidebar_text_color_hex", textHex)
        let statusBgHex = hex("status_bar_background_color_hex", bgHex)
        let statusTextHex = hex("status_bar_text_color_hex", textHex)

        let dialogBlend = intValue("dialog_muted_blend_percent", fallback: 50, min: 0, max: 100)
        let sidebarBlend = intValue("sidebar_muted_blend_percent", fallback: 50, min: 0, max: 100)
        let statusBlend = intValue("status_bar_muted_blend_percent", fallback: 50, min: 0, max: 100)

        let dialogMutedHex = ThemeBlendUtils.blendTextTowardBackground(
            textHex: dialogTextHex, bgHex: dialogBgHex, blendPercent: dialogBlend
        )
        let sidebarMutedHex = ThemeBlendUtils.blendTextTowardBackground(
            textHex: sidebarTextHex, bgHex: sidebarBgHex, blendPercent: sidebarBlend
        )
        let statusMutedHex = ThemeBlendUtils.blendTextTowardBackground(
            textHex: statusTextHex, bgHex: statusBgHex, blendPercent: statusBlend
        )

        let splitter = ThemeBlendUtils.splitterHoverPressed(from: borderHex)
        let headerBgHex = hex("sidebar_header_bg_hex", "#2b2b2b")
        let headerFocusHex = ThemeBlendUtils.sidebarHeaderFocusBg(baseHex: headerBgHex, themeID: themeID)

        let multiselectBgHex = hex("multiselect_background_color_hex", "#ffd700")
        let multiselectBg = Color(hex: multiselectBgHex) ?? .yellow

        let browseRGB = browse["transparency_color"] as? [Int] ?? [98, 98, 98]
        let browseBorderRGB = browse["browse_border_color"] as? [Int] ?? [0, 0, 0]
        let useDiamonds = browse["use_diamonds"] as? Bool ?? true
        let browseBorder = rgbColor(browseBorderRGB)
        let cellBgHex = ThemeBlendUtils.rgbHex(browseBorderRGB)
        let runningCellBg = ThemeBlendUtils.jobQueueRunningCellBackground(
            cellHex: cellBgHex,
            themeID: themeID
        )
        let actionBarBg = ThemeBlendUtils.darkerHex(cellBgHex, factor: 1.12)
        let jobQueueMutedHex = ThemeBlendUtils.blendTextTowardBackground(
            textHex: sidebarTextHex,
            bgHex: cellBgHex,
            blendPercent: sidebarBlend
        )
        let progressBgHex = hex("progress_bar_bg_hex", "#1a1a1a")
        let progressBorderHex = hex("progress_bar_border_hex", borderHex)
        let progressTextHex = hex("progress_bar_text_hex", sidebarTextHex)

        return ThemeColors(
            themeID: themeID,
            background: resolvedColor("default_background_color_hex", "#000000"),
            text: resolvedColor("text_color_hex", "#b6b6b6"),
            dialogBackground: resolvedColor("dialog_background_hex", "#2a2a2a"),
            dialogText: resolvedColor("dialog_text_color_hex", "#b6b6b6"),
            dialogInputBackground: resolvedColor("dialog_input_background_hex", "#000000"),
            dialogMutedText: Color(hex: dialogMutedHex) ?? .gray,
            sidebarBackground: resolvedColor("sidebar_background_color_hex", "#000000"),
            sidebarText: resolvedColor("sidebar_text_color_hex", "#b6b6b6"),
            sidebarMutedText: Color(hex: sidebarMutedHex) ?? .gray,
            sidebarHeaderBackground: resolvedColor("sidebar_header_bg_hex", "#2b2b2b"),
            sidebarHeaderBorder: Color(hex: borderHex) ?? Color(white: 0.25),
            sidebarHeaderText: resolvedColor("sidebar_text_color_hex", "#b6b6b6"),
            sidebarHeaderFocusBackground: Color(hex: headerFocusHex) ?? Color(white: 0.17),
            statusBarBackground: resolvedColor("status_bar_background_color_hex", "#000000"),
            statusBarText: resolvedColor("status_bar_text_color_hex", "#b6b6b6"),
            statusBarMutedText: Color(hex: statusMutedHex) ?? .gray,
            defaultBorder: Color(hex: borderHex) ?? .gray,
            splitterHandleHover: Color(hex: splitter.hover) ?? .gray,
            splitterHandlePressed: Color(hex: splitter.pressed) ?? .gray,
            viewBorderWidthPx: intValue("view_border_width_px", fallback: 2, min: 0, max: 8),
            buttonBgDefault: resolvedColor("button_bg_default_hex", "#16181c"),
            buttonTextDefault: resolvedColor("button_text_default_hex", "#b0bfd6"),
            buttonBorderDefault: resolvedColor("button_border_default_hex", "#38506b"),
            buttonBgHover: resolvedColor("button_bg_hover_hex", "#263447"),
            buttonTextHover: resolvedColor("button_text_hover_hex", "#bbecff"),
            buttonBorderHover: resolvedColor("button_border_hover_hex", "#41a6c6"),
            thumbnailGridBackground: resolvedColor("thumbnail_grid_background_color_hex", "#000000"),
            thumbnailText: resolvedColor("thumbnail_text_color_hex", "#b6b6b6"),
            defaultImageBorder: resolvedColor("default_image_color_hex", "#606060"),
            defaultImageBackground: resolvedColor("default_image_background_color_hex", "#000000"),
            defaultImageBorderWidth: intValue("default_image_border_width_index", fallback: 1, min: 0, max: 10),
            currentImageBorder: resolvedColor("current_image_border_color_hex", "#87ceeb"),
            currentImageBackground: resolvedColor("current_image_background_color_hex", "#0080b2"),
            currentImageBorderWidth: intValue("current_image_border_width_index", fallback: 2, min: 0, max: 10),
            multiselectBorder: resolvedColor("multiselect_border_color_hex", "#705d1f"),
            multiselectBackground: multiselectBg.opacity(130.0 / 255.0),
            multiselectBorderWidth: intValue("multiselect_border_width_index", fallback: 2, min: 0, max: 10),
            thumbnailEmptyFilterButtonBackground: resolvedColor("thumbnail_empty_filter_btn_bg_hex", "#161618"),
            thumbnailEmptyFilterButtonBackgroundHover: resolvedColor("thumbnail_empty_filter_btn_bg_hover_hex", "#263447"),
            thumbnailEmptyFilterButtonBorder: resolvedColor("thumbnail_empty_filter_btn_border_hex", "#38506b"),
            thumbnailEmptyFilterButtonBorderHover: resolvedColor("thumbnail_empty_filter_btn_border_hover_hex", "#41a6c6"),
            thumbnailEmptyFilterButtonTextHover: resolvedColor("thumbnail_empty_filter_btn_text_hover_hex", "#bbecff"),
            thumbnailFilenameOverlay: rgbaColor(
                "thumbnail_filename_overlay_rgba",
                darkFallback["thumbnail_filename_overlay_rgba"] as? String == nil
                    ? Color(white: 0, opacity: 240.0 / 255.0)
                    : Color(rgbaCSV: darkFallback["thumbnail_filename_overlay_rgba"] as? String ?? "0,0,0,240") ?? .black
            ),
            browseTransparencyColor: rgbColor(browseRGB),
            browseUseCheckerboard: useDiamonds,
            browseBorderColor: browseBorder,
            jobQueueCellBackground: browseBorder,
            jobQueueRunningCellBackground: Color(hex: runningCellBg) ?? browseBorder,
            jobQueueMutedText: Color(hex: jobQueueMutedHex) ?? Color(hex: sidebarMutedHex) ?? .gray,
            jobQueueActionBarBackground: Color(hex: actionBarBg) ?? browseBorder,
            jobQueueSelectionBorder: resolvedColor("current_image_border_color_hex", "#87ceeb"),
            progressBarBackground: Color(hex: progressBgHex) ?? Color(white: 0.1),
            progressBarBorder: Color(hex: progressBorderHex) ?? Color(hex: borderHex) ?? .gray,
            progressBarText: Color(hex: progressTextHex) ?? resolvedColor("sidebar_text_color_hex", "#b6b6b6"),
            progressBarFill: Color(hex: JobQueueLayout.progressBarFillHex) ?? Color(red: 0.20, green: 0.47, blue: 0.96),
            dialogMutedBlendPercent: dialogBlend,
            sidebarMutedBlendPercent: sidebarBlend,
            statusBarMutedBlendPercent: statusBlend
        )
    }

    private static func rgbColor(_ rgb: [Int]) -> Color {
        guard rgb.count >= 3 else { return Color(white: 0.38) }
        return Color(
            .sRGB,
            red: Double(rgb[0]) / 255,
            green: Double(rgb[1]) / 255,
            blue: Double(rgb[2]) / 255,
            opacity: 1
        )
    }
}

enum ThemeHexColor {
    static func components(from hex: String) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)? {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("#") { value.removeFirst() }

        let named: [String: String] = [
            "black": "000000", "white": "ffffff", "navy": "000080",
            "skyblue": "87ceeb", "gold": "ffd700",
        ]
        if let mapped = named[value] { value = mapped }

        guard value.count == 6 || value.count == 8,
              let number = UInt64(value, radix: 16) else { return nil }

        if value.count == 8 {
            return (
                r: CGFloat((number & 0xff00_0000) >> 24) / 255,
                g: CGFloat((number & 0x00ff_0000) >> 16) / 255,
                b: CGFloat((number & 0x0000_ff00) >> 8) / 255,
                a: CGFloat(number & 0x0000_00ff) / 255
            )
        }
        return (
            r: CGFloat((number & 0xff0000) >> 16) / 255,
            g: CGFloat((number & 0x00ff00) >> 8) / 255,
            b: CGFloat(number & 0x0000ff) / 255,
            a: 1
        )
    }
}

extension Color {
    init?(hex: String) {
        guard let c = ThemeHexColor.components(from: hex) else { return nil }
        self.init(.sRGB, red: Double(c.r), green: Double(c.g), blue: Double(c.b), opacity: Double(c.a))
    }

    /// AppKit-safe sRGB snapshot. `NSColor(Color).cgColor` can be black outside a SwiftUI
    /// environment — which is the packaged `.app` case, but not `swift run`.
    var nsColor: NSColor {
        let resolved = resolve(in: EnvironmentValues())
        return NSColor(
            srgbRed: CGFloat(resolved.red),
            green: CGFloat(resolved.green),
            blue: CGFloat(resolved.blue),
            alpha: CGFloat(resolved.opacity)
        )
    }

    init?(rgbaCSV: String) {
        let parts = rgbaCSV.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 4,
              let r = Double(parts[0]),
              let g = Double(parts[1]),
              let b = Double(parts[2]),
              let a = Double(parts[3]) else { return nil }
        self.init(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a / 255)
    }
}

private struct ThemeColorsEnvironmentKey: EnvironmentKey {
    static let defaultValue = ThemeColors.dark
}

extension EnvironmentValues {
    var themeColors: ThemeColors {
        get { self[ThemeColorsEnvironmentKey.self] }
        set { self[ThemeColorsEnvironmentKey.self] = newValue }
    }
}
