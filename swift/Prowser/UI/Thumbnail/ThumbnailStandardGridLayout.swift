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
        /// Row index → vertical span in document coordinates (for viewport intersection).
        var rowVerticalBounds: [(minY: CGFloat, maxY: CGFloat)]
        var usesUniformRowHeights: Bool
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
                rowLayout: .init(indexToRow: [:], rowToIndices: [:]),
                rowVerticalBounds: [],
                usesUniformRowHeights: true
            )
        }

        if !showFilename, !showImageSize {
            return computeUniformGrid(
                paths: paths,
                viewportWidth: viewportWidth,
                thumbnailSize: thumbnailSize,
                scrollbarWidth: scrollbarWidth
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
        var rowVerticalBounds: [(minY: CGFloat, maxY: CGFloat)] = []

        var currentRowNumber = 0
        var currentRowIndices: [Int] = []
        var yOffset = topMargin
        var col = 0
        var currentRowMaxHeight: CGFloat = 0
        var currentRowMinY = topMargin

        ThumbnailGridPerfDiagnostics.resetMeasureAdvanceCalls()

        func flushCurrentRow() {
            guard !currentRowIndices.isEmpty else { return }
            rowToIndices[currentRowNumber] = currentRowIndices
            for index in currentRowIndices {
                indexToRow[index] = currentRowNumber
            }
            rowVerticalBounds.append((minY: currentRowMinY, maxY: currentRowMinY + currentRowMaxHeight))
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
                currentRowMinY = yOffset
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
            ),
            rowVerticalBounds: rowVerticalBounds,
            usesUniformRowHeights: false
        )
    }

    /// Uniform cell height when filename/size overlays are disabled.
    private static func computeUniformGrid(
        paths: [String],
        viewportWidth: CGFloat,
        thumbnailSize: CGFloat,
        scrollbarWidth: CGFloat
    ) -> Result {
        let metrics = ThumbnailLayout.metrics(
            for: viewportWidth,
            itemCount: paths.count,
            showFilename: false,
            showImageSize: false,
            cellSize: thumbnailSize,
            scrollbarWidth: scrollbarWidth
        )
        let columns = max(1, metrics.columns)
        let rectSize = thumbnailSize + ThumbnailLayout.borderSpace
        let columnStride = metrics.cellWidth + ThumbnailLayout.borderSpace + ThumbnailLayout.thumbnailSpacing
        let topMargin = ThumbnailLayout.canvasInset + ThumbnailGridLayoutService.canvasTopMargin
        let spacing = ThumbnailLayout.verticalSpacing
        let cellHeight = rectSize
        let rowStride = cellHeight + spacing

        var itemFrames: [Int: NSRect] = [:]
        var indexToRow: [Int: Int] = [:]
        var rowToIndices: [Int: [Int]] = [:]
        var rowVerticalBounds: [(minY: CGFloat, maxY: CGFloat)] = []

        let rowCount = (paths.count + columns - 1) / columns
        for row in 0..<rowCount {
            let y = topMargin + CGFloat(row) * rowStride
            rowVerticalBounds.append((minY: y, maxY: y + cellHeight))
            var rowIndices: [Int] = []
            let start = row * columns
            let end = min(start + columns, paths.count)
            for index in start..<end {
                let col = index % columns
                let x = metrics.xOffset + CGFloat(col) * columnStride
                itemFrames[index] = NSRect(x: x, y: y, width: metrics.cellWidth, height: cellHeight)
                indexToRow[index] = row
                rowIndices.append(index)
            }
            rowToIndices[row] = rowIndices
        }

        var contentHeight = topMargin
        if rowCount > 0 {
            contentHeight += CGFloat(rowCount) * cellHeight + CGFloat(max(0, rowCount - 1)) * spacing
        }
        contentHeight += ThumbnailLayout.canvasInset + ThumbnailGridLayoutService.canvasBottomMargin

        return Result(
            itemFrames: itemFrames,
            overlayHeights: [:],
            wrappedLines: [:],
            columns: columns,
            contentSize: NSSize(width: viewportWidth, height: contentHeight),
            rowLayout: ThumbnailSectionedLayout.RowLayout(
                indexToRow: indexToRow,
                rowToIndices: rowToIndices
            ),
            rowVerticalBounds: rowVerticalBounds,
            usesUniformRowHeights: true
        )
    }
}
