import AppKit
import SwiftUI

/// Color blending helpers — port of `theme/theme.py`.
enum ThemeBlendUtils {
    static func blendTextTowardBackground(textHex: String, bgHex: String, blendPercent: Int) -> String {
        guard let text = NSColor(hex: textHex)?.usingColorSpace(.sRGB),
              let bg = NSColor(hex: bgHex)?.usingColorSpace(.sRGB) else {
            return textHex
        }
        let p = Double(max(0, min(100, blendPercent))) / 100.0
        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        var br: CGFloat = 0, bgG: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        text.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        bg.getRed(&br, green: &bgG, blue: &bb, alpha: &ba)
        let inv = 1.0 - p
        let r = Int(round(Double(tr * 255) * inv + Double(br * 255) * p))
        let g = Int(round(Double(tg * 255) * inv + Double(bgG * 255) * p))
        let b = Int(round(Double(tb * 255) * inv + Double(bb * 255) * p))
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    static func splitterHoverPressed(from chromeHex: String) -> (hover: String, pressed: String) {
        guard let c = NSColor(hex: chromeHex)?.usingColorSpace(.sRGB) else {
            return (chromeHex, chromeHex)
        }
        return (adjustBrightness(c, factor: 1.25), adjustBrightness(c, factor: 1.45))
    }

    static func sidebarHeaderFocusBg(baseHex: String, themeID: String) -> String {
        guard let c = NSColor(hex: baseHex)?.usingColorSpace(.sRGB) else { return baseHex }
        if themeID == "light" {
            return adjustBrightness(c, factor: 1.0 / 1.30)
        }
        return adjustBrightness(c, factor: 1.80)
    }

    static func rgbHex(_ rgb: [Int]) -> String {
        guard rgb.count >= 3 else { return "#000000" }
        return String(format: "#%02x%02x%02x", rgb[0], rgb[1], rgb[2])
    }

    static func darkerHex(_ hex: String, factor: CGFloat) -> String {
        guard let c = NSColor(hex: hex)?.usingColorSpace(.sRGB) else { return hex }
        return adjustBrightness(c, factor: 1.0 / factor)
    }

    /// Running job card fill: slightly darker on light theme, lighter on dark/user.
    static func jobQueueRunningCellBackground(cellHex: String, themeID: String) -> String {
        guard let base = NSColor(hex: cellHex)?.usingColorSpace(.sRGB) else { return cellHex }
        if themeID == "light" {
            var out = adjustBrightnessNS(base, factor: 1.0 / 1.12)
            if out.hexString == base.hexString {
                out = NSColor(
                    red: max(0, base.redComponent - 24 / 255),
                    green: max(0, base.greenComponent - 24 / 255),
                    blue: max(0, base.blueComponent - 24 / 255),
                    alpha: base.alphaComponent
                )
            }
            return out.hexString
        }
        var out = adjustBrightnessNS(base, factor: 1.12)
        if out.hexString == base.hexString {
            out = NSColor(
                red: min(1, base.redComponent + 36 / 255),
                green: min(1, base.greenComponent + 36 / 255),
                blue: min(1, base.blueComponent + 36 / 255),
                alpha: base.alphaComponent
            )
        }
        return out.hexString
    }

    private static func adjustBrightnessNS(_ color: NSColor, factor: CGFloat) -> NSColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let nb = factor >= 1 ? min(1, b * factor) : max(0, b * factor)
        return NSColor(hue: h, saturation: s, brightness: nb, alpha: a)
    }

    private static func adjustBrightness(_ color: NSColor, factor: CGFloat) -> String {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let nb = factor >= 1 ? min(1, b * factor) : max(0, b * factor)
        return NSColor(hue: h, saturation: s, brightness: nb, alpha: a).hexString
    }
}

extension NSColor {
    convenience init?(hex: String) {
        guard let color = Color(hex: hex) else { return nil }
        self.init(color)
    }

    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000000" }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
