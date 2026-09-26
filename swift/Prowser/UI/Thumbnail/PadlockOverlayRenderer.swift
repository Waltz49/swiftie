import AppKit

/// Padlock overlay for locked files. Port of `thumbnail_canvas._draw_padlock_overlay` / browse `view_manager.py`.
enum PadlockOverlayRenderer {
    enum Style {
        case thumbnail
        case browse
    }

    private static let padlockImage: NSImage? = AppAssets.padlockBright

    static func draw(in referenceRect: NSRect, style: Style) {
        let iconSize: CGFloat
        let margin: CGFloat
        switch style {
        case .thumbnail:
            iconSize = max(16, min(32, referenceRect.width / 8))
            margin = 4
        case .browse:
            iconSize = 64
            margin = 8
        }

        let padlockX = referenceRect.maxX - iconSize - margin
        let padlockY = referenceRect.minY + margin
        let dest = NSRect(x: padlockX, y: padlockY, width: iconSize, height: iconSize)

        if let image = padlockImage, image.size.width > 0, image.size.height > 0 {
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(
                in: dest,
                from: NSRect(origin: .zero, size: image.size),
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
            return
        }

        drawVectorFallback(in: dest, iconSize: iconSize)
    }

    private static func drawVectorFallback(in dest: NSRect, iconSize: CGFloat) {
        let lineWidth: CGFloat = iconSize >= 48 ? 4 : 2
        let cornerRadius: CGFloat = iconSize >= 48 ? 4 : 2
        let padlockColor = NSColor(red: 1, green: 215 / 255, blue: 0, alpha: 1)

        let bodyWidth = iconSize * 0.6
        let bodyHeight = iconSize * 0.7
        let bodyX = dest.minX + (iconSize - bodyWidth) / 2
        let bodyY = dest.minY + iconSize * 0.2
        let bodyRect = NSRect(x: bodyX, y: bodyY, width: bodyWidth, height: bodyHeight)

        padlockColor.setFill()
        NSBezierPath(roundedRect: bodyRect, xRadius: cornerRadius, yRadius: cornerRadius).fill()

        let shackleWidth = iconSize * 0.5
        let shackleHeight = iconSize * 0.3
        let shackleX = dest.minX + (iconSize - shackleWidth) / 2
        let shackleY = dest.minY + iconSize * 0.1
        let shackleRect = NSRect(x: shackleX, y: shackleY, width: shackleWidth, height: shackleHeight * 2)

        padlockColor.setStroke()
        let shackle = NSBezierPath()
        shackle.lineWidth = lineWidth
        shackle.appendArc(
            withCenter: NSPoint(x: shackleRect.midX, y: shackleRect.midY),
            radius: shackleWidth / 2,
            startAngle: 0,
            endAngle: 180,
            clockwise: false
        )
        shackle.stroke()
    }
}
