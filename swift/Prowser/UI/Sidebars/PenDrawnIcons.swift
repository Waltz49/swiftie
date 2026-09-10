import AppKit

/// Pen-drawn toolbar icons ported from `files/tree_toolbar.py` and `files/file_tree_handler.py`.
enum PenDrawnIcons {
    static func squeezeIcon(color: NSColor, size: CGFloat = 20) -> NSImage {
        drawImage(size: size) { _ in
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            color.setStroke()

            // >|<
            path.move(to: NSPoint(x: 1, y: 7))
            path.line(to: NSPoint(x: 6, y: 10))
            path.move(to: NSPoint(x: 1, y: 13))
            path.line(to: NSPoint(x: 6, y: 10))
            path.move(to: NSPoint(x: 9, y: 5))
            path.line(to: NSPoint(x: 9, y: 15))
            path.move(to: NSPoint(x: 17, y: 7))
            path.line(to: NSPoint(x: 12, y: 10))
            path.move(to: NSPoint(x: 17, y: 13))
            path.line(to: NSPoint(x: 12, y: 10))
            path.stroke()
        }
    }

    static func treeFilterIcon(
        mode: String,
        selected: Bool,
        hover: Bool,
        selectedColor: NSColor,
        unselectedColor: NSColor
    ) -> NSImage {
        let penColor = (selected || hover) ? selectedColor : unselectedColor
        return drawImage(size: 18) { _ in
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            penColor.setStroke()

            switch mode {
            case "all":
                path.move(to: NSPoint(x: 4, y: 4))
                path.line(to: NSPoint(x: 14, y: 14))
                path.move(to: NSPoint(x: 14, y: 4))
                path.line(to: NSPoint(x: 4, y: 14))
            case "images":
                path.appendRect(NSRect(x: 5, y: 5, width: 8, height: 8))
            default:
                path.move(to: NSPoint(x: 5, y: 4))
                path.line(to: NSPoint(x: 14, y: 4))
                path.line(to: NSPoint(x: 10, y: 10))
                path.line(to: NSPoint(x: 10, y: 15))
                path.move(to: NSPoint(x: 5, y: 4))
                path.line(to: NSPoint(x: 8, y: 10))
                path.line(to: NSPoint(x: 8, y: 15))
                path.move(to: NSPoint(x: 8, y: 15))
                path.line(to: NSPoint(x: 10, y: 15))
            }
            path.stroke()
        }
    }

    static func gearIcon(hover: Bool) -> NSImage? {
        let name = hover ? "gear_hover" : "gear"
        return AppAssets.nsImage(name: name, fileExtension: "svg")
    }

    static func dateSourceIcon(exif: Bool, color: NSColor, size: CGFloat = 12) -> NSImage {
        drawImage(size: size) { rect in
            if exif {
                color.setStroke()
                let body = NSBezierPath(rect: NSRect(x: 2, y: 3, width: 8, height: 6))
                body.lineWidth = 1
                body.stroke()
                let lens = NSBezierPath(ovalIn: NSRect(x: 4, y: 4.5, width: 4, height: 3))
                lens.lineWidth = 1
                lens.stroke()
            } else {
                let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
                circle.lineWidth = 1
                color.setStroke()
                circle.stroke()
                let font = NSFont.boldSystemFont(ofSize: 8)
                let text = "D" as NSString
                let textSize = text.size(withAttributes: [.font: font])
                text.draw(
                    at: NSPoint(
                        x: rect.midX - textSize.width / 2,
                        y: rect.midY - textSize.height / 2
                    ),
                    withAttributes: [.font: font, .foregroundColor: color]
                )
            }
        }
    }

    private static func drawImage(size: CGFloat, _ draw: (NSRect) -> Void) -> NSImage {
        let dimension = NSSize(width: size, height: size)
        let image = NSImage(size: dimension)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(NSRect(origin: .zero, size: dimension))
        image.unlockFocus()
        return image
    }
}
