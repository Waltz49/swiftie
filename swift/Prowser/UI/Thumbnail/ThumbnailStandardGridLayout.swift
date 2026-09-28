import AppKit
import Foundation

/// Standard thumbnail grid with variable row heights (port of Python `_update_thumbnail_rectangles` non-section branch).
enum ThumbnailStandardGridLayout {
    struct Result {
        var itemFrames: [Int: NSRect]
        var overlayHeights: [Int: CGFloat]
        var wrappedLines: [Int: [String]]
        var columns: Int
        var contentSize: NSSize
        var rowLayout: ThumbnailSectionedLayout.RowLayout
    }

    static func compute(
        paths: [String],
        viewportWidth: CGFloat,
        thumbnailSize: CGFloat,
        showFilename: Bool,
        showImageSize: Bool,
        showExtensions: Bool,
        basenamesNeedingExtensions: Set<String>,
        scrollbarWidth: CGFloat = 0,
        overlayCache: ThumbnailFilenameOverlayCache = .shared
    ) -> Result {
        guard !paths.isEmpty else {
            return Result(
                itemFrames: [:],
                overlayHeights: [:],
                wrappedLines: [:],
                columns: 1,
                contentSize: NSSize(width: viewportWidth, height: 300),
                rowLayout: .init(indexToRow: [:], rowToIndices: [:])
            )
        }

        let metrics = ThumbnailLayout.metrics(
            for: viewportWidth,
            itemCount: paths.count,
            showFilename: showFilename,
            showImageSize: showImageSize,
            cellSize: thumbnailSize,
            scrollbarWidth: scrollbarWidth
        )
        let columns = max(1, metrics.columns)
        let rectSize = thumbnailSize + ThumbnailLayout.borderSpace
        let columnStride = metrics.cellWidth + ThumbnailLayout.borderSpace + ThumbnailLayout.thumbnailSpacing
        let topMargin = ThumbnailLayout.canvasInset + ThumbnailGridLayoutService.canvasTopMargin
        let spacing = ThumbnailLayout.verticalSpacing

        var itemFrames: [Int: NSRect] = [:]
        var overlayHeights: [Int: CGFloat] = [:]
        var wrappedLines: [Int: [String]] = [:]
        var indexToRow: [Int: Int] = [:]
        var rowToIndices: [Int: [Int]] = [:]

        var currentRowNumber = 0
        var currentRowIndices: [Int] = []
        var yOffset = topMargin
        var col = 0
        var currentRowMaxHeight: CGFloat = 0

        func flushCurrentRow() {
            guard !currentRowIndices.isEmpty else { return }
            rowToIndices[currentRowNumber] = currentRowIndices
            for index in currentRowIndices {
                indexToRow[index] = currentRowNumber
            }
            currentRowNumber += 1
            currentRowIndices = []
        }

        for (index, path) in paths.enumerated() {
            let overlay = ThumbnailFilenameOverlayService.overlay(
                for: path,
                cellWidth: metrics.cellWidth,
                showFilename: showFilename,
                showImageSize: showImageSize,
                showExtensions: showExtensions,
                basenamesNeedingExtensions: basenamesNeedingExtensions,
                displayStyle: .basename,
                wrapMode: .cellWidth,
                cache: overlayCache
            )
            overlayHeights[index] = overlay.overlayHeight
            wrappedLines[index] = overlay.wrappedLines

            let x = metrics.xOffset + CGFloat(col) * columnStride
            let cellHeight = rectSize + overlay.overlayHeight
            itemFrames[index] = NSRect(x: x, y: yOffset, width: metrics.cellWidth, height: cellHeight)
            currentRowMaxHeight = max(currentRowMaxHeight, cellHeight)
            currentRowIndices.append(index)

            col += 1
            if col >= columns {
                flushCurrentRow()
                yOffset += currentRowMaxHeight + spacing
                col = 0
                currentRowMaxHeight = 0
            }
        }

        if col > 0 {
            flushCurrentRow()
            yOffset += currentRowMaxHeight
        }

        let contentHeight = yOffset
            + ThumbnailLayout.canvasInset
            + ThumbnailGridLayoutService.canvasBottomMargin
        return Result(
            itemFrames: itemFrames,
            overlayHeights: overlayHeights,
            wrappedLines: wrappedLines,
            columns: columns,
            contentSize: NSSize(width: viewportWidth, height: contentHeight),
            rowLayout: ThumbnailSectionedLayout.RowLayout(
                indexToRow: indexToRow,
                rowToIndices: rowToIndices
            )
        )
    }
}
