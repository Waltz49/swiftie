import AppKit
import Foundation

/// Grid layout math ported from `thumbnails/thumbnail_constants.py` (simplified).
enum ThumbnailLayout {
    static let minCellSize: CGFloat = 80
    static let maxCellSize: CGFloat = 450
    static let defaultCellSize: CGFloat = 150
    static let horizontalSpacing: CGFloat = 8
    static let verticalSpacing: CGFloat = 8
    static let canvasInset: CGFloat = 12
    static let labelHeight: CGFloat = 18
    /// Space around each thumbnail for borders (Python `BORDER_SPACE`).
    static let borderSpace: CGFloat = 4
    /// Inset between cell border and image (Python `_paint_thumbnail` inner_margin).
    static let innerMargin: CGFloat = 6
    static let cornerRadius: CGFloat = 7

    struct GridMetrics {
        let columns: Int
        let cellWidth: CGFloat
        let cellHeight: CGFloat
        let contentSize: NSSize
    }

    static func overlayLabelHeight(showFilename: Bool, showImageSize: Bool) -> CGFloat {
        switch (showFilename, showImageSize) {
        case (false, false): return 0
        case (true, true): return labelHeight * 2
        default: return labelHeight
        }
    }

    static func metrics(
        for viewportWidth: CGFloat,
        itemCount: Int,
        showFilename: Bool,
        showImageSize: Bool = false,
        cellSize: CGFloat = defaultCellSize
    ) -> GridMetrics {
        let targetCell = min(max(cellSize, minCellSize), maxCellSize)
        let usableWidth = max(viewportWidth - canvasInset * 2, minCellSize)
        let columns = max(1, Int((usableWidth + horizontalSpacing) / (targetCell + horizontalSpacing)))
        let cellWidth = (usableWidth - horizontalSpacing * CGFloat(columns - 1)) / CGFloat(columns)
        let imageHeight = cellWidth
        let label = overlayLabelHeight(showFilename: showFilename, showImageSize: showImageSize)
        let cellHeight = imageHeight + label
        let rows = max(1, Int(ceil(Double(itemCount) / Double(columns))))
        let contentHeight = canvasInset * 2
            + CGFloat(rows) * cellHeight
            + CGFloat(max(0, rows - 1)) * verticalSpacing
        return GridMetrics(
            columns: columns,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            contentSize: NSSize(width: viewportWidth, height: contentHeight)
        )
    }

    static func frame(for index: Int, metrics: GridMetrics) -> NSRect {
        let col = index % metrics.columns
        let row = index / metrics.columns
        let x = canvasInset + CGFloat(col) * (metrics.cellWidth + horizontalSpacing)
        let y = canvasInset + CGFloat(row) * (metrics.cellHeight + verticalSpacing)
        return NSRect(x: x, y: y, width: metrics.cellWidth, height: metrics.cellHeight)
    }

    /// Square image area above the filename label.
    static func imageFrame(
        for index: Int,
        metrics: GridMetrics,
        showFilename: Bool,
        showImageSize: Bool = false
    ) -> NSRect {
        let cell = frame(for: index, metrics: metrics)
        let label = overlayLabelHeight(showFilename: showFilename, showImageSize: showImageSize)
        let imageHeight = metrics.cellHeight - label
        return NSRect(x: cell.minX, y: cell.minY, width: cell.width, height: imageHeight)
    }

    /// Rounded cell background + border rect (inset by border space).
    static func thumbnailBorderRect(in imageFrame: NSRect) -> NSRect {
        imageFrame.insetBy(dx: borderSpace, dy: borderSpace)
    }

    /// Inner rect where the pixmap is scaled with aspect fit and centered.
    static func imageContentRect(in imageFrame: NSRect) -> NSRect {
        thumbnailBorderRect(in: imageFrame).insetBy(dx: innerMargin, dy: innerMargin)
    }

    static func visibleIndices(
        in visibleRect: NSRect,
        metrics: GridMetrics,
        itemCount: Int
    ) -> [Int] {
        guard itemCount > 0 else { return [] }
        var result: [Int] = []
        for index in 0..<itemCount {
            let frame = frame(for: index, metrics: metrics)
            if frame.intersects(visibleRect.insetBy(dx: -metrics.cellWidth, dy: -metrics.cellHeight)) {
                result.append(index)
            }
        }
        return result
    }
}
