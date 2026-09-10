import SwiftUI

/// Resolved theme palette for SwiftUI surfaces.
struct ThemeColors: Equatable {
    var background: Color
    var text: Color
    var sidebarBackground: Color
    var sidebarText: Color
    var sidebarHeaderBackground: Color
    var sidebarHeaderBorder: Color
    var sidebarHeaderText: Color
    var thumbnailGridBackground: Color
    var currentImageBorder: Color
    var currentImageBackground: Color
    var multiselectBorder: Color
    var multiselectBackground: Color
    var statusBarBackground: Color
    var statusBarText: Color
    var thumbnailFilenameOverlay: Color

    static let dark = ThemeColors(
        background: Color(hex: "#000000") ?? .black,
        text: Color(hex: "#b6b6b6") ?? .gray,
        sidebarBackground: Color(hex: "#000000") ?? .black,
        sidebarText: Color(hex: "#b6b6b6") ?? .gray,
        sidebarHeaderBackground: Color(hex: "#2b2b2b") ?? Color(white: 0.17),
        sidebarHeaderBorder: Color(hex: "#404040") ?? Color(white: 0.25),
        sidebarHeaderText: Color(hex: "#b6b6b6") ?? .gray,
        thumbnailGridBackground: Color(hex: "#000000") ?? .black,
        currentImageBorder: Color(hex: "#87ceeb") ?? .cyan,
        currentImageBackground: Color(hex: "#0080b2") ?? .blue,
        multiselectBorder: Color(hex: "#705d1f") ?? .yellow,
        multiselectBackground: Color(hex: "#ffd700") ?? .yellow,
        statusBarBackground: Color(hex: "#000000") ?? .black,
        statusBarText: Color(hex: "#b6b6b6") ?? .gray,
        thumbnailFilenameOverlay: Color(white: 0, opacity: 240.0 / 255.0)
    )

    static let light = ThemeColors(
        background: Color(hex: "#c0c0c0") ?? Color(white: 0.75),
        text: .black,
        sidebarBackground: Color(hex: "#c0c0c0") ?? Color(white: 0.75),
        sidebarText: .black,
        sidebarHeaderBackground: Color(hex: "#3f5666") ?? Color(white: 0.55),
        sidebarHeaderBorder: Color(hex: "#808080") ?? .gray,
        sidebarHeaderText: .black,
        thumbnailGridBackground: Color(hex: "#c0c0c0") ?? Color(white: 0.75),
        currentImageBorder: Color(hex: "navy") ?? .blue,
        currentImageBackground: Color(hex: "skyblue") ?? .cyan,
        multiselectBorder: Color(hex: "#e65100") ?? .orange,
        multiselectBackground: Color(hex: "gold") ?? .yellow,
        statusBarBackground: Color(hex: "#c0c0c0") ?? Color(white: 0.75),
        statusBarText: .black,
        thumbnailFilenameOverlay: Color(white: 0.98, opacity: 252.0 / 255.0)
    )

    static func fromDictionary(_ dict: [String: Any], fallback: ThemeColors) -> ThemeColors {
        func color(_ key: String, _ defaultColor: Color) -> Color {
            guard let raw = dict[key] as? String else { return defaultColor }
            return Color(hex: raw) ?? defaultColor
        }
        func rgbaColor(_ key: String, _ defaultColor: Color) -> Color {
            guard let raw = dict[key] as? String else { return defaultColor }
            return Color(rgbaCSV: raw) ?? defaultColor
        }
        return ThemeColors(
            background: color("default_background_color_hex", fallback.background),
            text: color("text_color_hex", fallback.text),
            sidebarBackground: color("sidebar_background_color_hex", fallback.sidebarBackground),
            sidebarText: color("sidebar_text_color_hex", fallback.sidebarText),
            sidebarHeaderBackground: color("sidebar_header_bg_hex", fallback.sidebarHeaderBackground),
            sidebarHeaderBorder: color("sidebar_header_border_hex", fallback.sidebarHeaderBorder),
            sidebarHeaderText: color("sidebar_header_text_hex", fallback.sidebarHeaderText),
            thumbnailGridBackground: color("thumbnail_grid_background_color_hex", fallback.thumbnailGridBackground),
            currentImageBorder: color("current_image_border_color_hex", fallback.currentImageBorder),
            currentImageBackground: color("current_image_background_color_hex", fallback.currentImageBackground),
            multiselectBorder: color("multiselect_border_color_hex", fallback.multiselectBorder),
            multiselectBackground: color("multiselect_background_color_hex", fallback.multiselectBackground),
            statusBarBackground: color("status_bar_background_color_hex", fallback.statusBarBackground),
            statusBarText: color("status_bar_text_color_hex", fallback.statusBarText),
            thumbnailFilenameOverlay: rgbaColor("thumbnail_filename_overlay_rgba", fallback.thumbnailFilenameOverlay)
        )
    }
}

extension Color {
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("#") { value.removeFirst() }

        let named: [String: String] = [
            "black": "000000", "white": "ffffff", "navy": "000080",
            "skyblue": "87ceeb", "gold": "ffd700",
        ]
        if let mapped = named[value] { value = mapped }

        guard value.count == 6 || value.count == 8,
              let number = UInt64(value, radix: 16) else { return nil }

        let r, g, b, a: Double
        if value.count == 8 {
            r = Double((number & 0xff00_0000) >> 24) / 255
            g = Double((number & 0x00ff_0000) >> 16) / 255
            b = Double((number & 0x0000_ff00) >> 8) / 255
            a = Double(number & 0x0000_00ff) / 255
        } else {
            r = Double((number & 0xff0000) >> 16) / 255
            g = Double((number & 0x00ff00) >> 8) / 255
            b = Double(number & 0x0000ff) / 255
            a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
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
