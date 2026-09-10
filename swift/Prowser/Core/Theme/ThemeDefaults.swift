import Foundation

/// Default theme palettes — port of `theme/theme_defaults.py`.
enum ThemeDefaults {
    static func userThemeColors() -> [String: Any] {
        [
            "default_background_color_hex": "#a86c29",
            "text_color_hex": "#0ce612",
            "dialog_background_hex": "#282828",
            "dialog_text_color_hex": "#e2d2c3",
            "thumbnail_grid_background_color_hex": "#000000",
            "sidebar_background_color_hex": "#000005",
            "sidebar_text_color_hex": "#fdfdf1",
            "sidebar_header_bg_hex": "#212833",
            "sidebar_header_border_hex": "#424242",
            "sidebar_header_text_hex": "#fdfdf1",
            "status_bar_background_color_hex": "#2b282c",
            "status_bar_text_color_hex": "#e2d2c3",
            "current_image_border_color_hex": "#33bcfd",
            "current_image_background_color_hex": "#2895cb",
            "multiselect_border_color_hex": "#d0ae22",
            "multiselect_background_color_hex": "#9d8419",
            "thumbnail_empty_filter_btn_bg_hex": "#161618",
            "thumbnail_empty_filter_btn_bg_hover_hex": "#263447",
            "thumbnail_empty_filter_btn_border_hex": "#38506b",
            "thumbnail_empty_filter_btn_border_hover_hex": "#41a6c6",
            "thumbnail_empty_filter_btn_text_hover_hex": "#bbecff",
        ]
    }

    static func darkThemeColors() -> [String: Any] {
        [
            "default_background_color_hex": "#000000",
            "text_color_hex": "#b6b6b6",
            "dialog_background_hex": "#2a2a2a",
            "dialog_text_color_hex": "#b6b6b6",
            "thumbnail_grid_background_color_hex": "#000000",
            "sidebar_background_color_hex": "#000000",
            "sidebar_text_color_hex": "#b6b6b6",
            "sidebar_header_bg_hex": "#2b2b2b",
            "sidebar_header_border_hex": "#404040",
            "sidebar_header_text_hex": "#b6b6b6",
            "status_bar_background_color_hex": "#000000",
            "status_bar_text_color_hex": "#b6b6b6",
            "current_image_border_color_hex": "#87ceeb",
            "current_image_background_color_hex": "#0080b2",
            "multiselect_border_color_hex": "#705d1f",
            "multiselect_background_color_hex": "#ffd700",
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
            "default_background_color_hex": "#c0c0c0",
            "text_color_hex": "black",
            "dialog_background_hex": "#ececec",
            "dialog_text_color_hex": "black",
            "thumbnail_grid_background_color_hex": "#c0c0c0",
            "sidebar_background_color_hex": "#c0c0c0",
            "sidebar_text_color_hex": "black",
            "sidebar_header_bg_hex": "#3f5666",
            "sidebar_header_border_hex": "#808080",
            "sidebar_header_text_hex": "black",
            "status_bar_background_color_hex": "#c0c0c0",
            "status_bar_text_color_hex": "black",
            "current_image_border_color_hex": "navy",
            "current_image_background_color_hex": "skyblue",
            "multiselect_border_color_hex": "#e65100",
            "multiselect_background_color_hex": "gold",
            "thumbnail_filename_overlay_rgba": "248, 250, 252, 252",
            "thumbnail_empty_filter_btn_bg_hex": "#f0f2f5",
            "thumbnail_empty_filter_btn_bg_hover_hex": "#e3f2fd",
            "thumbnail_empty_filter_btn_border_hex": "#b0bec5",
            "thumbnail_empty_filter_btn_border_hover_hex": "#2196f3",
            "thumbnail_empty_filter_btn_text_hover_hex": "#0d47a1",
        ]
    }

    static let knownExtensionList = [
        "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif",
        "cr2", "nef", "arw", "dng", "orf", "rw2", "pef", "srw", "psd", "svg",
    ]

    static let defaultRootDirectories = ["/Users", "/Volumes", "/tmp"]
}
