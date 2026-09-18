import AppKit
import Foundation

/// Sectioned thumbnail grid (EXIF date / duplicates). Port of `thumbnail_canvas.py` `is_section_mode` layout.
enum ThumbnailSectionedLayout {
    static let sectionedColumnSpacing: CGFloat = 30
    static let separatorHeight: CGFloat = 30

    struct SeparatorItem {
        var rect: NSRect = .zero
        var isDuplicateLine: Bool
        var label: String?
        var isBold: Bool
    }

    /// Visual row membership for keyboard ↑/↓ (port of Python `_index_to_row` / `_row_to_indices`).
    struct RowLayout: Equatable, Sendable {
        var indexToRow: [Int: Int]
        var rowToIndices: [Int: [Int]]

        var totalRows: Int {
            guard let maxRow = rowToIndices.keys.max() else { return 0 }
            return maxRow + 1
        }

        /// Port of `navigation_manager.compute_next_index` vertical branch for segmented layouts.
        func verticalTarget(currentIndex: Int, stepSign: Int) -> Int {
            guard let currentRow = indexToRow[currentIndex] else { return currentIndex }
            let rowIndices = rowToIndices[currentRow] ?? []
            guard let colPosition = rowIndices.firstIndex(of: currentIndex) else { return currentIndex }
            let targetRow = currentRow + stepSign
            guard targetRow >= 0, targetRow < totalRows else { return currentIndex }
            let targetRowIndices = rowToIndices[targetRow] ?? []
            guard !targetRowIndices.isEmpty else { return currentIndex }
            if colPosition < targetRowIndices.count {
                return targetRowIndices[colPosition]
            }
            return targetRowIndices[targetRowIndices.count - 1]
        }
    }

    struct Result {
        var itemFrames: [Int: NSRect]
        var separators: [SeparatorItem]
        var columns: Int
        var contentSize: NSSize
        var overlayHeights: [Int: CGFloat]
        var rowLayout: RowLayout
    }

    /// Largest overlay band in duplicate section mode (for thumbnail size calculation).
    static func maxOverlayHeightEstimate(
        paths: [String],
        showFilename: Bool,
        showImageSize: Bool,
        thumbnailSize: CGFloat
    ) -> CGFloat {
        guard showFilename || showImageSize else { return 0 }
        let font = NSFont(name: "Arial", size: 14) ?? NSFont.systemFont(ofSize: 14)
        let maxTextWidth = min(thumbnailSize * 2, ThumbnailLayout.maxCellSize)
        var maxOverlay: CGFloat = 0
        for path in paths {
            maxOverlay = max(
                maxOverlay,
                overlayHeight(
                    for: path,
                    showFilename: showFilename,
                    showImageSize: showImageSize,
                    font: font,
                    maxTextWidth: maxTextWidth,
                    duplicateMode: true
                )
            )
        }
        return maxOverlay
    }

    static func duplicateFilenameOverlay(for path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        let filename = (path as NSString).lastPathComponent
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var displayDir = dir
        if displayDir.hasPrefix(home) {
            displayDir = "~" + String(displayDir.dropFirst(home.count))
        }
        return "\(displayDir)\n──────────\n\(filename)"
    }

    static func computeDuplicateLayout(
        paths: [String],
        sections: [DuplicateGroupPresentation.DuplicateSection],
        viewportWidth: CGFloat,
        thumbnailSize: CGFloat,
        showFilename: Bool,
        showImageSize: Bool,
        currentImagePath: String?
    ) -> Result {
        let spacing = ThumbnailLayout.thumbnailSpacing
        let border = ThumbnailLayout.borderSpace
        let rectSize = thumbnailSize + border
        let topMargin = ThumbnailLayout.canvasInset + ThumbnailGridLayoutService.canvasTopMargin

        let font = NSFont(name: "Arial", size: 14) ?? NSFont.systemFont(ofSize: 14)
        let maxTextWidth = min(thumbnailSize * 2, ThumbnailLayout.maxCellSize)

        var maxCellTextWidth: CGFloat = 0
        if showFilename {
            for path in paths {
                let text = duplicateFilenameOverlay(for: path)
                let width = measureTextWidth(text, font: font, maxWidth: maxTextWidth)
                maxCellTextWidth = max(maxCellTextWidth, width)
            }
        }

        var cellWidth = rectSize + spacing
        if maxCellTextWidth > 0 {
            cellWidth = max(cellWidth, maxCellTextWidth + spacing)
        }

        let extraMargin = max(0, (maxTextWidth - rectSize) / 2) + 10
        let minMargin = ThumbnailLayout.baseMargin + extraMargin
        let availableWidth = max(viewportWidth - minMargin * 2, 1)
        let columns = max(
            1,
            Int((availableWidth + sectionedColumnSpacing) / (cellWidth + sectionedColumnSpacing))
        )

        let actualColumns = min(columns, max(1, paths.count))
        let totalGridWidth =
            CGFloat(actualColumns) * cellWidth
            + CGFloat(max(0, actualColumns - 1)) * sectionedColumnSpacing
            - spacing
        let xOffset = max(minMargin, (viewportWidth - totalGridWidth) / 2)

        var sectionStartToSeparatorIndex: [Int: Int] = [:]
        var separators: [SeparatorItem] = []
        for (sepIndex, section) in sections.enumerated() {
            sectionStartToSeparatorIndex[section.startIndex] = sepIndex
            let containsActive = sectionContains(
                pathIndex: paths.firstIndex(of: currentImagePath ?? "") ?? -1,
                sectionStart: section.startIndex,
                sectionIndex: sepIndex,
                sections: sections,
                pathCount: paths.count
            )
            separators.append(
                SeparatorItem(
                    isDuplicateLine: true,
                    label: nil,
                    isBold: containsActive
                )
            )
        }

        var itemFrames: [Int: NSRect] = [:]
        var overlayHeights: [Int: CGFloat] = [:]
        var indexToRow: [Int: Int] = [:]
        var rowToIndices: [Int: [Int]] = [:]
        var currentRowNumber = 0
        var currentRowIndices: [Int] = []
        var yOffset = topMargin
        var col = 0
        var currentRowMaxHeight: CGFloat = 0
        var positionedSeparators: Set<Int> = []

        func flushCurrentRow() {
            guard !currentRowIndices.isEmpty else { return }
            rowToIndices[currentRowNumber] = currentRowIndices
            for index in currentRowIndices {
                indexToRow[index] = currentRowNumber
            }
            currentRowNumber += 1
            currentRowIndices = []
        }

        for (thumbIndex, path) in paths.enumerated() {
            if let sepIndex = sectionStartToSeparatorIndex[thumbIndex],
               !positionedSeparators.contains(sepIndex) {
                if col > 0 {
                    flushCurrentRow()
                    yOffset += currentRowMaxHeight
                    col = 0
                    currentRowMaxHeight = 0
                }
                separators[sepIndex].rect = NSRect(
                    x: ThumbnailLayout.baseMargin,
                    y: yOffset,
                    width: max(1, viewportWidth - ThumbnailLayout.baseMargin * 2),
                    height: separatorHeight
                )
                positionedSeparators.insert(sepIndex)
                yOffset += separatorHeight
            }

            let overlayH = overlayHeight(
                for: path,
                showFilename: showFilename,
                showImageSize: showImageSize,
                font: font,
                maxTextWidth: maxTextWidth,
                duplicateMode: true
            )
            overlayHeights[thumbIndex] = overlayH

            if col == 0, thumbIndex > 0, sectionStartToSeparatorIndex[thumbIndex] == nil {
                let prevIndex = thumbIndex - 1
                if sectionIndex(for: prevIndex, sections: sections) == sectionIndex(for: thumbIndex, sections: sections) {
                    yOffset += spacing
                }
            }

            let x = xOffset + CGFloat(col) * (cellWidth + sectionedColumnSpacing)
            let rowH = rectSize + overlayH
            itemFrames[thumbIndex] = NSRect(x: x, y: yOffset, width: cellWidth, height: rowH)
            currentRowMaxHeight = max(currentRowMaxHeight, rowH)
            currentRowIndices.append(thumbIndex)

            col += 1
            if col >= actualColumns {
                flushCurrentRow()
                yOffset += currentRowMaxHeight
                col = 0
                currentRowMaxHeight = 0
            }
        }

        if col > 0 {
            flushCurrentRow()
            yOffset += currentRowMaxHeight
        }

        var contentBottom = yOffset
        for frame in itemFrames.values {
            contentBottom = max(contentBottom, frame.maxY)
        }
        for separator in separators {
            contentBottom = max(contentBottom, separator.rect.maxY)
        }
        let contentHeight = contentBottom
            + ThumbnailLayout.canvasInset
            + ThumbnailGridLayoutService.canvasBottomMargin
        return Result(
            itemFrames: itemFrames,
            separators: separators,
            columns: actualColumns,
            contentSize: NSSize(width: viewportWidth, height: contentHeight),
            overlayHeights: overlayHeights,
            rowLayout: RowLayout(indexToRow: indexToRow, rowToIndices: rowToIndices)
        )
    }

    private static func sectionIndex(
        for pathIndex: Int,
        sections: [DuplicateGroupPresentation.DuplicateSection]
    ) -> Int? {
        guard pathIndex >= 0 else { return nil }
        var result: Int?
        for (idx, section) in sections.enumerated() {
            if section.startIndex <= pathIndex {
                result = idx
            }
        }
        return result
    }

    private static func sectionContains(
        pathIndex: Int,
        sectionStart: Int,
        sectionIndex: Int,
        sections: [DuplicateGroupPresentation.DuplicateSection],
        pathCount: Int
    ) -> Bool {
        guard pathIndex >= 0 else { return false }
        let end: Int
        if sectionIndex + 1 < sections.count {
            end = sections[sectionIndex + 1].startIndex
        } else {
            end = pathCount
        }
        return sectionStart <= pathIndex && pathIndex < end
    }

    private static func rowHeight(
        paths: [String],
        indices: Range<Int>,
        rectSize: CGFloat,
        showFilename: Bool,
        showImageSize: Bool,
        font: NSFont,
        maxTextWidth: CGFloat
    ) -> CGFloat {
        var maxOverlay: CGFloat = 0
        for index in indices {
            guard paths.indices.contains(index) else { continue }
            maxOverlay = max(
                maxOverlay,
                overlayHeight(
                    for: paths[index],
                    showFilename: showFilename,
                    showImageSize: showImageSize,
                    font: font,
                    maxTextWidth: maxTextWidth,
                    duplicateMode: true
                )
            )
        }
        return rectSize + maxOverlay
    }

    private static func overlayHeight(
        for path: String,
        showFilename: Bool,
        showImageSize: Bool,
        font: NSFont,
        maxTextWidth: CGFloat,
        duplicateMode: Bool
    ) -> CGFloat {
        guard showFilename || showImageSize else { return 0 }
        var lines: [String] = []
        if showFilename {
            lines.append(duplicateMode ? duplicateFilenameOverlay(for: path) : (path as NSString).lastPathComponent)
        }
        if showImageSize {
            lines.append(" ") // placeholder height; grid measures dimensions separately when enabled
        }
        var total: CGFloat = 0
        for line in lines {
            let height = measureTextHeight(line, font: font, maxWidth: maxTextWidth - 8)
            total += max(ThumbnailLayout.labelHeight, height)
        }
        return total + 4
    }

    private static func measureTextWidth(_ text: String, font: NSFont, maxWidth: CGFloat) -> CGFloat {
        let attr = [NSAttributedString.Key.font: font]
        let full = (text as NSString).size(withAttributes: attr).width
        return min(full, maxWidth)
    }

    private static func measureTextHeight(_ text: String, font: NSFont, maxWidth: CGFloat) -> CGFloat {
        let attr = [NSAttributedString.Key.font: font]
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attr
        )
        return ceil(rect.height)
    }
}
