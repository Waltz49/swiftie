import Foundation

/// Theme config keys — port of `theme/theme_service.py`.
enum ThemeKeys {
    static let builtinThemeIDs: Set<String> = ["dark", "light", "user", "system"]
    static let editableBuiltinThemeIDs: Set<String> = ["dark", "light", "user"]
    static let browseTransparencyThemeIDs: Set<String> = ["dark", "light", "user"]

    static let userThemeColorKeys: [String] = [
        "default_background_color_hex",
        "text_color_hex",
        "dialog_background_hex",
        "dialog_text_color_hex",
        "dialog_input_background_hex",
        "thumbnail_grid_background_color_hex",
        "thumbnail_text_color_hex",
        "default_image_color_hex",
        "default_image_background_color_hex",
        "current_image_border_color_hex",
        "current_image_background_color_hex",
        "multiselect_border_color_hex",
        "multiselect_background_color_hex",
        "sidebar_header_bg_hex",
        "sidebar_background_color_hex",
        "sidebar_text_color_hex",
        "status_bar_background_color_hex",
        "status_bar_text_color_hex",
        "default_border_color_hex",
        "button_bg_default_hex",
        "button_border_default_hex",
        "button_bg_hover_hex",
        "button_border_hover_hex",
        "button_text_default_hex",
        "button_text_hover_hex",
    ]

    static let borderWidthKeys: [String] = [
        "default_image_border_width_index",
        "current_image_border_width_index",
        "multiselect_border_width_index",
    ]

    static let viewChromeKeys: [String] = ["view_border_width_px"]

    static let mutedBlendKeys: [String] = [
        "dialog_muted_blend_percent",
        "sidebar_muted_blend_percent",
        "status_bar_muted_blend_percent",
    ]

    static let collapseGroupKeys: [String] = [
        "text_background",
        "dialogs",
        "sidebar_chrome",
        "button_settings",
        "thumbnails_selection",
        "browse_colors",
    ]

    static let maxImageBorderWidthPx = 10
    static let minViewChromeBorderWidthPx = 0
    static let maxViewChromeBorderWidthPx = 8
    static let mutedBlendMinPercent = 0
    static let mutedBlendMaxPercent = 100

    static func colorOverridesKey(for themeID: String) -> String {
        switch themeID {
        case "light": return "light_theme_colors"
        case "dark": return "dark_theme_colors"
        case "user": return "user_theme_colors"
        default: return "user_theme_colors"
        }
    }
}
