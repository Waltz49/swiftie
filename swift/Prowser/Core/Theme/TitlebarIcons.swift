import AppKit
import SwiftUI

/// Themed titlebar chip icons — port of `theme/titlebar_icons.py`.
enum TitlebarIcons {
    static let iconSize: CGFloat = 14
    static let buttonSize: CGFloat = 20

    struct ChipColors {
        let background: Color
        let hoverBackground: Color
        let pressedBackground: Color
        let border: Color
        let hoverBorder: Color
    }

    static func chipColors(for colors: ThemeColors) -> ChipColors {
        let base = NSColor(colors.sidebarHeaderBackground)
        return ChipColors(
            background: Color(nsColor: base.blended(withFraction: 0.35, of: .white) ?? base),
            hoverBackground: Color(nsColor: base.blended(withFraction: 0.5, of: .white) ?? base),
            pressedBackground: Color(nsColor: base.blended(withFraction: 0.22, of: .white) ?? base),
            border: Color(nsColor: base.blended(withFraction: 0.22, of: .white) ?? base),
            hoverBorder: Color(nsColor: base.blended(withFraction: 0.28, of: .white) ?? base)
        )
    }

    static func iconColors(for colors: ThemeColors, hover: Bool) -> NSColor {
        let chip = chipColors(for: colors)
        let bg = hover ? chip.hoverBackground : chip.background
        let normal = contrastingForeground(for: bg)
        if hover {
            return hoverForeground(normal: normal, hoverBackground: chip.hoverBackground)
        }
        return normal
    }

    static func hideIcon(mode: String, colors: ThemeColors, hover: Bool) -> NSImage {
        let color = iconColors(for: colors, hover: hover)
        return mode == "plus" ? drawPlus(color: color) : drawMinus(color: color)
    }

    static func toolsIcon(colors: ThemeColors, hover: Bool) -> NSImage {
        drawPaneTools(color: iconColors(for: colors, hover: hover))
    }

    static func flyoutIcon(paneMode: Bool, colors: ThemeColors, hover: Bool) -> NSImage {
        let color = iconColors(for: colors, hover: hover)
        return paneMode ? drawFlyout(color: color) : drawFlyin(color: color)
    }

    private static func contrastingForeground(for background: Color) -> NSColor {
        let bg = NSColor(background)
        let light = NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.95, alpha: 1)
        let dark = NSColor(calibratedRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        return contrastRatio(light, bg) >= contrastRatio(dark, bg) ? light : dark
    }

    private static func hoverForeground(normal: NSColor, hoverBackground: Color) -> NSColor {
        let hoverBG = NSColor(hoverBackground)
        if relativeLuminance(hoverBG) < 0.5 {
            return normal.blended(withFraction: 0.25, of: .white) ?? normal
        }
        return normal.blended(withFraction: 0.25, of: .black) ?? normal
    }

    private static func contrastRatio(_ fg: NSColor, _ bg: NSColor) -> CGFloat {
        let l1 = relativeLuminance(fg)
        let l2 = relativeLuminance(bg)
        let lighter = max(l1, l2)
        let darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func relativeLuminance(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        func channel(_ value: CGFloat) -> CGFloat {
            if value <= 0.03928 { return value / 12.92 }
            return pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb.redComponent)
            + 0.7152 * channel(rgb.greenComponent)
            + 0.0722 * channel(rgb.blueComponent)
    }

    private static func renderIcon(size: CGFloat, _ draw: (CGFloat) -> Void) -> NSImage {
        let dimension = NSSize(width: size, height: size)
        let image = NSImage(size: dimension)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(size)
        image.unlockFocus()
        return image
    }

    private static func drawMinus(color: NSColor) -> NSImage {
        renderIcon(size: iconSize) { size in
            let path = NSBezierPath()
            path.lineWidth = 2
            path.lineCapStyle = .round
            color.setStroke()
            let y = size * 0.5
            path.move(to: NSPoint(x: size * 0.25, y: y))
            path.line(to: NSPoint(x: size * 0.75, y: y))
            path.stroke()
        }
    }

    private static func drawPlus(color: NSColor) -> NSImage {
        renderIcon(size: iconSize) { size in
            let path = NSBezierPath()
            path.lineWidth = 2
            path.lineCapStyle = .round
            color.setStroke()
            let mid = size * 0.5
            path.move(to: NSPoint(x: mid, y: size * 0.25))
            path.line(to: NSPoint(x: mid, y: size * 0.75))
            path.move(to: NSPoint(x: size * 0.25, y: mid))
            path.line(to: NSPoint(x: size * 0.75, y: mid))
            path.stroke()
        }
    }

    private static func drawPaneTools(color: NSColor) -> NSImage {
        renderIcon(size: iconSize) { size in
            color.setFill()
            let bars: [(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat)] = [
                (size * 0.125, size * 0.1875, size * 0.75, size * 0.125),
                (size * 0.1875, size * 0.4375, size * 0.625, size * 0.125),
                (size * 0.25, size * 0.6875, size * 0.5, size * 0.125),
            ]
            for bar in bars {
                NSBezierPath(roundedRect: NSRect(x: bar.x, y: bar.y, width: bar.w, height: bar.h), xRadius: 0.5, yRadius: 0.5).fill()
            }
        }
    }

    private static func drawFlyout(color: NSColor) -> NSImage {
        renderIcon(size: iconSize) { size in
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            color.setStroke()
            path.move(to: NSPoint(x: size * 0.1875, y: size * 0.40625))
            path.line(to: NSPoint(x: size * 0.1875, y: size * 0.8125))
            path.line(to: NSPoint(x: size * 0.8125, y: size * 0.8125))
            path.line(to: NSPoint(x: size * 0.8125, y: size * 0.5))
            path.stroke()

            path.move(to: NSPoint(x: size * 0.4375, y: size * 0.59375))
            path.line(to: NSPoint(x: size * 0.75, y: size * 0.28125))
            path.move(to: NSPoint(x: size * 0.75, y: size * 0.28125))
            path.line(to: NSPoint(x: size * 0.75, y: size * 0.46875))
            path.move(to: NSPoint(x: size * 0.75, y: size * 0.28125))
            path.line(to: NSPoint(x: size * 0.5625, y: size * 0.28125))
            path.stroke()
        }
    }

    private static func drawFlyin(color: NSColor) -> NSImage {
        renderIcon(size: iconSize) { size in
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            color.setStroke()
            path.move(to: NSPoint(x: size * 0.8125, y: size * 0.40625))
            path.line(to: NSPoint(x: size * 0.8125, y: size * 0.8125))
            path.line(to: NSPoint(x: size * 0.1875, y: size * 0.8125))
            path.line(to: NSPoint(x: size * 0.1875, y: size * 0.5))
            path.stroke()

            path.move(to: NSPoint(x: size * 0.5625, y: size * 0.59375))
            path.line(to: NSPoint(x: size * 0.25, y: size * 0.28125))
            path.move(to: NSPoint(x: size * 0.25, y: size * 0.28125))
            path.line(to: NSPoint(x: size * 0.25, y: size * 0.46875))
            path.move(to: NSPoint(x: size * 0.25, y: size * 0.28125))
            path.line(to: NSPoint(x: size * 0.4375, y: size * 0.28125))
            path.stroke()
        }
    }
}

@MainActor
struct SidebarTitlebarChipButton: View {
    @Environment(AppState.self) private var appState
    @State private var hovering = false
    @State private var pressed = false

    let tooltip: String
    let image: (ThemeColors, Bool) -> NSImage
    let action: () -> Void

    var body: some View {
        let colors = appState.theme.colors
        let chip = TitlebarIcons.chipColors(for: colors)
        let background = pressed ? chip.pressedBackground : (hovering ? chip.hoverBackground : chip.background)
        let border = hovering ? chip.hoverBorder : chip.border

        Button(action: action) {
            Image(nsImage: image(colors, hovering))
                .resizable()
                .scaledToFit()
                .frame(width: TitlebarIcons.iconSize, height: TitlebarIcons.iconSize)
                .frame(width: TitlebarIcons.buttonSize, height: TitlebarIcons.buttonSize)
                .background(background)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .onHover { hovering = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
    }
}
