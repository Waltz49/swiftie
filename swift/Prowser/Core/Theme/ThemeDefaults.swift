import Foundation

/// Default theme palettes — port of `theme/theme_defaults.py`.
enum ThemeDefaults {
    static func userThemeColors() -> [String: Any] {
        [
            "default_background_color_hex": "#a86c29",
            "text_color_hex": "#0ce612",
            "dialog_background_hex": "#282828",
            "dialog_text_color_hex": "#e2d2c3",
            "dialog_input_background_hex": "#000000",
            "thumbnail_grid_background_color_hex": "#000000",
            "thumbnail_text_color_hex": "#e2d2c3",
            "default_image_color_hex": "#a6a6a6",
            "default_image_background_color_hex": "#000000",
            "current_image_border_color_hex": "#33bcfd",
            "current_image_background_color_hex": "#2895cb",
            "multiselect_border_color_hex": "#d0ae22",
            "multiselect_background_color_hex": "#9d8419",
            "sidebar_header_bg_hex": "#3f5666",
            "sidebar_background_color_hex": "#000005",
            "sidebar_text_color_hex": "#fdfdf1",
            "status_bar_background_color_hex": "#2b282c",
            "status_bar_text_color_hex": "#e2d2c3",
            "default_border_color_hex": "#7cb4c8",
            "button_bg_default_hex": "#233346",
            "button_border_default_hex": "#38506b",
            "button_bg_hover_hex": "#263447",
            "button_border_hover_hex": "#41a6c6",
            "button_text_default_hex": "#eaffdd",
            "button_text_hover_hex": "#bbecff",
            "default_image_border_width_index": 1,
            "current_image_border_width_index": 3,
            "multiselect_border_width_index": 3,
            "view_border_width_px": 2,
            "dialog_muted_blend_percent": 50,
            "sidebar_muted_blend_percent": 50,
            "status_bar_muted_blend_percent": 50,
        ]
    }

    static func darkThemeColors() -> [String: Any] {
        [
            "current_image_background_color_hex": "#0080b2",
            "current_image_border_color_hex": "#87ceeb",
            "current_image_border_width_index": 2,
            "default_background_color_hex": "#000000",
            "thumbnail_grid_background_color_hex": "#000000",
            "dialog_background_hex": "#2a2a2a",
            "dialog_text_color_hex": "#b6b6b6",
            "dialog_input_background_hex": "#000000",
            "default_border_color_hex": "#606060",
            "default_image_background_color_hex": "#000000",
            "default_image_border_width_index": 1,
            "default_image_color_hex": "#606060",
            "multiselect_background_color_hex": "#ffd700",
            "multiselect_border_color_hex": "#705d1f",
            "multiselect_border_width_index": 2,
            "sidebar_header_bg_hex": "#2b2b2b",
            "sidebar_background_color_hex": "#000000",
            "sidebar_text_color_hex": "#b6b6b6",
            "thumbnail_text_color_hex": "#b6b6b6",
            "status_bar_background_color_hex": "#000000",
            "status_bar_text_color_hex": "#b6b6b6",
            "text_color_hex": "#b6b6b6",
            "view_border_width_px": 2,
            "button_bg_default_hex": "#16181c",
            "button_border_default_hex": "#38506b",
            "button_bg_hover_hex": "#263447",
            "button_border_hover_hex": "#41a6c6",
            "button_text_default_hex": "#b0bfd6",
            "button_text_hover_hex": "#bbecff",
            "dialog_muted_blend_percent": 50,
            "sidebar_muted_blend_percent": 50,
            "status_bar_muted_blend_percent": 50,
            "thumbnail_filename_overlay_rgba": "0, 0, 0, 240",
            "thumbnail_empty_filter_btn_bg_hex": "#161618",
            "thumbnail_empty_filter_btn_bg_hover_hex": "#263447",
            "thumbnail_empty_filter_btn_border_hex": "#38506b",
            "thumbnail_empty_filter_btn_border_hover_hex": "#41a6c6",
            "thumbnail_empty_filter_btn_text_hover_hex": "#bbecff",
        ]
    }

    static func lightThemeColors() -> [String: Any] {
        [
            "current_image_background_color_hex": "skyblue",
            "current_image_border_color_hex": "navy",
            "current_image_border_width_index": 2,
            "default_background_color_hex": "#c0c0c0",
            "thumbnail_grid_background_color_hex": "#c0c0c0",
            "dialog_background_hex": "#ececec",
            "dialog_text_color_hex": "black",
            "dialog_input_background_hex": "#ffffff",
            "default_border_color_hex": "#cfd8dc",
            "default_image_background_color_hex": "#c0c0c0",
            "default_image_border_width_index": 1,
            "default_image_color_hex": "#222222",
            "multiselect_background_color_hex": "gold",
            "multiselect_border_color_hex": "#e65100",
            "multiselect_border_width_index": 2,
            "sidebar_header_bg_hex": "#212833",
            "sidebar_background_color_hex": "#c0c0c0",
            "sidebar_text_color_hex": "black",
            "thumbnail_text_color_hex": "black",
            "status_bar_background_color_hex": "#c0c0c0",
            "status_bar_text_color_hex": "black",
            "text_color_hex": "black",
            "view_border_width_px": 2,
            "button_bg_default_hex": "#f0f4f8",
            "button_border_default_hex": "#7a9ab8",
            "button_bg_hover_hex": "#dde8f4",
            "button_border_hover_hex": "#4a7aaa",
            "button_text_default_hex": "#1a2a3a",
            "button_text_hover_hex": "#0a1a2a",
            "dialog_muted_blend_percent": 50,
            "sidebar_muted_blend_percent": 50,
            "status_bar_muted_blend_percent": 50,
            "thumbnail_filename_overlay_rgba": "248, 250, 252, 252",
            "thumbnail_empty_filter_btn_bg_hex": "#f0f2f5",
            "thumbnail_empty_filter_btn_bg_hover_hex": "#e3f2fd",
            "thumbnail_empty_filter_btn_border_hex": "#b0bec5",
            "thumbnail_empty_filter_btn_border_hover_hex": "#2196f3",
            "thumbnail_empty_filter_btn_text_hover_hex": "#0d47a1",
        ]
    }

    static func defaultBrowseTransparencyEntry() -> [String: Any] {
        [
            "transparency_color": [98, 98, 98],
            "use_diamonds": true,
            "browse_border_color": [0, 0, 0],
        ]
    }

    static func defaultBrowseTransparencySettings() -> [String: Any] {
        let entry = defaultBrowseTransparencyEntry()
        return [
            "dark": entry,
            "light": entry,
            "user": entry,
        ]
    }

    static func defaultsForThemeID(_ themeID: String) -> [String: Any] {
        switch themeID {
        case "light": return lightThemeColors()
        case "user": return userThemeColors()
        default: return darkThemeColors()
        }
    }

    static let knownExtensionList = [
        "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif",
        "cr2", "nef", "arw", "dng", "orf", "rw2", "pef", "srw", "psd", "svg",
    ]

    static let defaultRootDirectories = ["/Users", "/Volumes", "/tmp"]
}
