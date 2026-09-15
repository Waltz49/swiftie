import AppKit
import Foundation

/// Grid layout math ported from `thumbnails/thumbnail_constants.py` (simplified).
enum ThumbnailLayout {
    static let minCellSize: CGFloat = 80
    static let maxCellSize: CGFloat = 450
    static let defaultCellSize: CGFloat = 150
    /// Python `THUMBNAIL_SPACING` — horizontal/vertical gap between cell slots in the grid.
    static let thumbnailSpacing: CGFloat = 4
    static let horizontalSpacing: CGFloat = thumbnailSpacing
    static let verticalSpacing: CGFloat = thumbnailSpacing
    static let baseMargin: CGFloat = ThumbnailGridLayoutService.baseMargin
    static let canvasInset: CGFloat = 8
    /// Height in points of the top cover strip, measured down from the top of the thumbnail pane.
    /// Hides the previous-row sliver left by auto-scroll. Change this to make the bar taller or shorter.
    static let topCoverBandHeight: CGFloat = 20
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
        let xOffset: CGFloat
        let contentSize: NSSize
    }

    static func overlayLabelHeight(showFilename: Bool, showImageSize: Bool) -> CGFloat {
        switch (showFilename, showImageSize) {
        case (false, false): return 0
        case (true, true): return labelHeight * 2
        default: return labelHeight
        }
    }

    /// Basenames that appear with more than one extension in the current view (Python `_basenames_needing_extensions`).
    static func basenamesWithMultipleExtensions(in paths: [String]) -> Set<String> {
        var extensionsByStem: [String: Set<String>] = [:]
        for path in paths {
            let filename = (path as NSString).lastPathComponent
            let stem = ((filename as NSString).deletingPathExtension as NSString).lastPathComponent
            let ext = (filename as NSString).pathExtension.lowercased()
            if ext.isEmpty {
                extensionsByStem[stem, default: []].insert("")
            } else {
                extensionsByStem[stem, default: []].insert(ext)
            }
        }
        return Set(
            extensionsByStem.filter { pair in
                let exts = pair.value.filter { !$0.isEmpty }
                return exts.count > 1
            }.map(\.key)
        )
    }

    static func overlayDisplayFilename(
        for path: String,
        showExtensions: Bool,
        basenamesNeedingExtensions: Set<String>
    ) -> String {
        let filename = (path as NSString).lastPathComponent
        let nsName = filename as NSString
        let ext = nsName.pathExtension
        guard !ext.isEmpty else { return filename }
        let stem = (nsName.deletingPathExtension as NSString).lastPathComponent
        if showExtensions || basenamesNeedingExtensions.contains(stem) {
            return filename
        }
        return stem
    }

    static func metrics(
        for viewportWidth: CGFloat,
        itemCount: Int,
        showFilename: Bool,
        showImageSize: Bool = false,
        cellSize: CGFloat = defaultCellSize,
        scrollbarWidth: CGFloat = 0
    ) -> GridMetrics {
        let targetCell = min(
            max(cellSize, CGFloat(ThumbnailGridLayoutService.minThumbnailSize)),
            maxCellSize
        )
        // Python `calculate_grid_layout`: columns from fixed slot width, not stretched cells.
        let availableWidth = max(viewportWidth - scrollbarWidth - baseMargin * 2, 1)
        let cellSlot = targetCell + borderSpace + thumbnailSpacing
        let columns = max(1, Int(availableWidth / cellSlot))
        let cellWidth = targetCell
        let imageHeight = cellWidth
        let label = overlayLabelHeight(showFilename: showFilename, showImageSize: showImageSize)
        let cellHeight = imageHeight + label
        let rows = max(1, Int(ceil(Double(itemCount) / Double(columns))))

        let xOffset = baseMargin

        let contentHeight = canvasInset * 2
            + CGFloat(rows) * cellHeight
            + CGFloat(max(0, rows - 1)) * verticalSpacing
        return GridMetrics(
            columns: columns,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            xOffset: xOffset,
            contentSize: NSSize(width: viewportWidth, height: contentHeight)
        )
    }

    static func frame(for index: Int, metrics: GridMetrics) -> NSRect {
        let col = index % metrics.columns
        let row = index / metrics.columns
        let columnStride = metrics.cellWidth + borderSpace + thumbnailSpacing
        let x = metrics.xOffset + CGFloat(col) * columnStride
        let y = canvasInset + CGFloat(row) * (metrics.cellHeight + verticalSpacing)
        return NSRect(x: x, y: y, width: metrics.cellWidth, height: metrics.cellHeight)
    }

    /// Square image area above the filename/size overlay (flipped view: image at top of cell).
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

    /// Label band below the thumbnail image (centered overlay text is drawn here).
    static func overlayFrame(
        for index: Int,
        metrics: GridMetrics,
        showFilename: Bool,
        showImageSize: Bool = false
    ) -> NSRect {
        let cell = frame(for: index, metrics: metrics)
        let label = overlayLabelHeight(showFilename: showFilename, showImageSize: showImageSize)
        let imageHeight = metrics.cellHeight - label
        return NSRect(x: cell.minX, y: cell.minY + imageHeight, width: cell.width, height: label)
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
        indicesIntersecting(
            visibleRect.insetBy(dx: -metrics.cellWidth, dy: -metrics.cellHeight),
            metrics: metrics,
            itemCount: itemCount,
            referenceNodeFrames: nil
        )
    }

    /// Index range intersecting `rect` without scanning the full list when in grid mode.
    static func indicesIntersecting(
        _ rect: NSRect,
        metrics: GridMetrics,
        itemCount: Int,
        referenceNodeFrames: [Int: NSRect]?
    ) -> [Int] {
        guard itemCount > 0, !rect.isEmpty else { return [] }
        if let referenceNodeFrames {
            return (0..<itemCount).filter { index in
                guard let frame = referenceNodeFrames[index] else { return false }
                return frame.intersects(rect)
            }
        }
        let columns = max(1, metrics.columns)
        let rowStride = metrics.cellHeight + verticalSpacing
        let colStride = metrics.cellWidth + borderSpace + thumbnailSpacing
        guard rowStride > 0, colStride > 0 else { return [] }

        let expanded = rect
        let minRow = max(0, Int(floor((expanded.minY - canvasInset) / rowStride)))
        let maxRow = min(
            (itemCount - 1) / columns,
            Int(floor((expanded.maxY - canvasInset) / rowStride))
        )
        let minCol = max(0, Int(floor((expanded.minX - metrics.xOffset) / colStride)))
        let maxCol = min(columns - 1, Int(floor((expanded.maxX - metrics.xOffset) / colStride)))

        guard minRow <= maxRow, minCol <= maxCol else { return [] }

        var result: [Int] = []
        for row in minRow...maxRow {
            for col in minCol...maxCol {
                let index = row * columns + col
                if index >= itemCount { continue }
                if frame(for: index, metrics: metrics).intersects(rect) {
                    result.append(index)
                }
            }
        }
        return result
    }
}
