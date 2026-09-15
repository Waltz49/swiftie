import CoreGraphics
import Foundation

/// Optimal thumbnail grid sizing. Port of `thumbnails/thumbnail_operations_manager.py`.
enum ThumbnailGridLayoutService {
    /// Python `MIN_THUMBNAIL_SIZE` from `files/image_extensions_helpers.py`.
    static let minThumbnailSize = 150
    static let maxThumbnailSize = 450
    /// Python `BASE_MARGIN`.
    static let baseMargin: CGFloat = 20
    /// Python `CANVAS_TOTAL_TOP_MARGIN`.
    static let canvasTopMargin: CGFloat = 14
    /// Python `CANVAS_TOTAL_BOTTOM_MARGIN`.
    static let canvasBottomMargin: CGFloat = 10

    static func calculateOptimalThumbnailSize(
        numImages: Int,
        viewportWidth: CGFloat,
        viewportHeight: CGFloat,
        scrollbarWidth: CGFloat,
        overlayHeight: CGFloat
    ) -> Int {
        let availableWidth = viewportWidth - scrollbarWidth - baseMargin * 2
        let result = calculateGridForImages(
            numImages: numImages,
            availableWidth: availableWidth,
            availableHeight: viewportHeight,
            overlayHeight: overlayHeight
        )
        return result.optimalSize
    }

    static func calculateGridForImages(
        numImages: Int,
        availableWidth: CGFloat,
        availableHeight: CGFloat,
        overlayHeight: CGFloat
    ) -> (optimalSize: Int, columns: Int, rows: Int) {
        if numImages == 0 {
            return (minThumbnailSize, 1, 1)
        }
        if availableWidth <= 0 || availableHeight <= 0 {
            return (minThumbnailSize, 1, 1)
        }
        if numImages == 1 {
            let single = Int(min(availableWidth, availableHeight) * 0.8)
            return (max(minThumbnailSize, single), 1, 1)
        }

        var bestEfficiency = 0.0
        var optimalSize = minThumbnailSize
        var bestColumns = 1
        var bestRows = 1

        var naturalColumns = 1
        var bestRatio = Double.infinity
        for cols in 1...numImages {
            let rows = (numImages + cols - 1) / cols
            var ratio = Double(abs(cols - rows)) / Double(max(cols, rows))
            if numImages <= 4, cols < rows {
                ratio += 0.01
            }
            if ratio < bestRatio {
                bestRatio = ratio
                naturalColumns = cols
            }
        }

        let viewportHeight = availableHeight - canvasTopMargin - canvasBottomMargin
        let startY: CGFloat = 0
        let spacing = ThumbnailLayout.thumbnailSpacing

        for testSize in minThumbnailSize...maxThumbnailSize {
            let cellSize = CGFloat(testSize) + ThumbnailLayout.borderSpace + spacing
            let rectSize = CGFloat(testSize) + ThumbnailLayout.borderSpace
            let cellHeight = rectSize + overlayHeight + spacing

            let maxColumnsByWidth = max(1, Int(availableWidth / cellSize))
            var columns = min(naturalColumns, maxColumnsByWidth)
            if columns > numImages { columns = numImages }
            var rows = (numImages + columns - 1) / columns

            var lastRow = rows - 1
            var lastBottom = startY + CGFloat(lastRow) * cellHeight + rectSize + overlayHeight

            if lastBottom > viewportHeight, maxColumnsByWidth > columns {
                columns = max(1, Int(availableWidth / cellSize))
                if columns > numImages { columns = numImages }
                rows = (numImages + columns - 1) / columns
                lastRow = rows - 1
                lastBottom = startY + CGFloat(lastRow) * cellHeight + rectSize + overlayHeight
            }

            if lastBottom <= viewportHeight {
                let totalGridWidth = CGFloat(columns) * cellSize
                let totalGridHeight = CGFloat(rows) * cellHeight - spacing
                var efficiency = (totalGridWidth * totalGridHeight) / (availableWidth * viewportHeight)
                let aspectPenalty = Double(abs(columns - rows)) / Double(max(columns, rows))
                efficiency *= (1.0 - aspectPenalty * 0.1)
                if efficiency > bestEfficiency {
                    bestEfficiency = efficiency
                    optimalSize = testSize
                    bestColumns = columns
                    bestRows = rows
                }
            }
        }

        if bestColumns <= 1 {
            let cellSize = CGFloat(minThumbnailSize) + ThumbnailLayout.borderSpace + spacing
            bestColumns = max(1, Int(availableWidth / cellSize))
            bestRows = (numImages + bestColumns - 1) / bestColumns
            optimalSize = minThumbnailSize
        }

        if optimalSize > minThumbnailSize {
            let cellSize = CGFloat(optimalSize) + ThumbnailLayout.borderSpace + spacing
            let rectSize = CGFloat(optimalSize) + ThumbnailLayout.borderSpace
            let cellHeight = rectSize + overlayHeight + spacing
            var lastRow = bestRows - 1
            var lastBottom = startY + CGFloat(lastRow) * cellHeight + rectSize + overlayHeight

            if lastBottom > viewportHeight {
                let maxPossibleColumns = min(numImages, max(1, Int(availableWidth / cellSize)))
                if maxPossibleColumns > bestColumns {
                    for testColumns in (bestColumns + 1)...maxPossibleColumns {
                        let testRows = (numImages + testColumns - 1) / testColumns
                        let testLastRow = testRows - 1
                        let testCellHeight = rectSize + overlayHeight + spacing
                        let testLastBottom = startY + CGFloat(testLastRow) * testCellHeight + rectSize + overlayHeight
                        if testLastBottom <= viewportHeight {
                            bestColumns = testColumns
                            bestRows = testRows
                            break
                        }
                    }
                    lastRow = bestRows - 1
                    lastBottom = startY + CGFloat(lastRow) * cellHeight + rectSize + overlayHeight
                }

                if lastBottom > viewportHeight {
                    let maxRows = max(1, Int((viewportHeight - startY) / cellHeight))
                    let maxThumbnailHeight = Int((viewportHeight - startY) / CGFloat(maxRows) - overlayHeight - spacing - ThumbnailLayout.borderSpace)
                    if maxThumbnailHeight >= minThumbnailSize {
                        optimalSize = maxThumbnailHeight
                        let newCellSize = CGFloat(optimalSize) + ThumbnailLayout.borderSpace + spacing
                        bestColumns = max(1, Int(availableWidth / newCellSize))
                        if bestColumns > numImages { bestColumns = numImages }
                        bestRows = (numImages + bestColumns - 1) / bestColumns
                    }
                }
            }
        }

        return (optimalSize, bestColumns, bestRows)
    }
}
