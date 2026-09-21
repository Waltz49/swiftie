import CoreGraphics
import Foundation

/// Checkerboard used for transparent images (Python `_draw_diamond_pattern` / browse view).
enum TransparencyCheckerboard {
    private static let tile: CGFloat = 8
    private static let baseComponent: CGFloat = 128.0 / 255.0
    private static let alternateComponent: CGFloat = 96.0 / 255.0

    static func draw(in rect: CGRect, context: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }

        context.setFillColor(
            CGColor(srgbRed: baseComponent, green: baseComponent, blue: baseComponent, alpha: 1)
        )
        context.fill(rect)

        context.setFillColor(
            CGColor(srgbRed: alternateComponent, green: alternateComponent, blue: alternateComponent, alpha: 1)
        )

        let startCol = Int(floor(rect.minX / tile))
        let startRow = Int(floor(rect.minY / tile))
        var row = startRow
        var y = CGFloat(startRow) * tile
        while y < rect.maxY {
            var col = startCol
            var x = CGFloat(startCol) * tile
            while x < rect.maxX {
                if (row + col).isMultiple(of: 2) {
                    let cell = CGRect(x: x, y: y, width: tile, height: tile).intersection(rect)
                    if !cell.isNull {
                        context.fill(cell)
                    }
                }
                x += tile
                col += 1
            }
            y += tile
            row += 1
        }
    }
}
