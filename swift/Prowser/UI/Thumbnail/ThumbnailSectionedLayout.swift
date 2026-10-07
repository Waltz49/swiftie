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
        var wrappedLines: [Int: [String]]
        var rowLayout: RowLayout
        var rowVerticalBounds: [(minY: CGFloat, maxY: CGFloat)] = []
        var usesUniformRowHeights: Bool = false
    }

    /// Largest overlay band in duplicate section mode (for thumbnail size calculation).
    static func maxOverlayHeightEstimate(
        paths: [String],
        showFilename: Bool,
        showImageSize: Bool,
        thumbnailSize: CGFloat,
        showExtensions: Bool = true,
        basenamesNeedingExtensions: Set<String> = [],
        duplicatePathDisplay: Bool = true
    ) -> CGFloat {
        guard showFilename || showImageSize else { return 0 }
        let thumb = Int(thumbnailSize.rounded(.up))
        var maxOverlay: CGFloat = 0
        for path in paths {
            let overlay = ThumbnailFilenameOverlayService.overlay(
                for: path,
                cellWidth: min(thumbnailSize * 2, ThumbnailLayout.maxCellSize),
                showFilename: showFilename,
                showImageSize: showImageSize,
                showExtensions: showExtensions,
                basenamesNeedingExtensions: basenamesNeedingExtensions,
                displayStyle: duplicatePathDisplay ? .duplicatePath : .basename,
                wrapMode: .sectionedMax(thumbnailSize: thumb)
            )
            maxOverlay = max(maxOverlay, overlay.overlayHeight)
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

    /// Wrapped overlay lines for duplicate mode (port of Python `_wrap_filename_text`; no eliding).
    static func duplicateOverlayWrappedLines(
        for path: String,
        font: NSFont,
        lineWrapWidth: CGFloat
    ) -> [String] {
        let inner = max(1, lineWrapWidth)
        return duplicateFilenameOverlay(for: path)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }
            .flatMap { wrapFilenameText($0, maxWidth: inner, font: font) }
    }

    static func wrapFilenameText(_ text: String, maxWidth: CGFloat, font: NSFont) -> [String] {
        if text.contains("\n") {
            return text.split(separator: "\n", omittingEmptySubsequences: false).flatMap { part in
                wrapFilenameText(String(part), maxWidth: maxWidth, font: font)
            }
        }
        if measureAdvance(text, font: font) <= maxWidth {
            return [text]
        }

        var lines: [String] = []
        var currentLine = ""

        func flushCurrent() {
            guard !currentLine.isEmpty else { return }
            lines.append(currentLine)
            currentLine = ""
        }

        func appendToken(_ token: String) {
            let test = currentLine + token
            if measureAdvance(test, font: font) <= maxWidth {
                currentLine = test
                return
            }
            if !currentLine.isEmpty {
                flushCurrent()
                appendToken(token)
                return
            }
            for char in token {
                let testChar = currentLine + String(char)
                if measureAdvance(testChar, font: font) <= maxWidth {
                    currentLine = testChar
                } else {
                    flushCurrent()
                    currentLine = String(char)
                }
            }
        }

        var currentWord = ""
        for char in text {
            if char == " " || char == "_" || char == "-" || char == "." {
                if !currentWord.isEmpty {
                    appendToken(currentWord)
                    currentWord = ""
                }
                appendToken(String(char))
            } else {
                currentWord.append(char)
            }
        }
        if !currentWord.isEmpty {
            appendToken(currentWord)
        }
        flushCurrent()
        return lines.isEmpty ? [text] : lines
    }

    static func measureAdvance(_ text: String, font: NSFont) -> CGFloat {
        ThumbnailFontMetricsCache.advanceWidth(for: text, font: font)
    }

    static func computeDuplicateLayout(
        paths: [String],
        sections: [DuplicateGroupPresentation.DuplicateSection],
        viewportWidth: CGFloat,
        thumbnailSize: CGFloat,
        showFilename: Bool,
        showImageSize: Bool,
        showExtensions: Bool,
        basenamesNeedingExtensions: Set<String>,
        currentImagePath: String?
    ) -> Result {
        computeSectionedGridLayout(
            paths: paths,
            sectionStarts: sections.map(\.startIndex),
            separatorLabels: sections.map { _ in nil as String? },
            duplicateSeparatorLine: true,
            viewportWidth: viewportWidth,
            thumbnailSize: thumbnailSize,
            showFilename: showFilename,
            showImageSize: showImageSize,
            showExtensions: showExtensions,
            basenamesNeedingExtensions: basenamesNeedingExtensions,
            displayStyle: .duplicatePath,
            currentImagePath: currentImagePath,
            sectionIndexForPath: { pathIndex, sectionStarts, pathCount in
                exifSectionIndex(for: pathIndex, sectionStarts: sectionStarts, pathCount: pathCount)
            },
            sectionContainsActive: { pathIndex, sectionIndex, sectionStarts, pathCount in
                guard pathIndex >= 0, sectionIndex < sectionStarts.count else { return false }
                let start = sectionStarts[sectionIndex]
                let end = sectionIndex + 1 < sectionStarts.count ? sectionStarts[sectionIndex + 1] : pathCount
                return start <= pathIndex && pathIndex < end
            }
        )
    }

    static func computeExifSectionLayout(
        paths: [String],
        sections: [ExifSectionPresentation.Section],
        viewportWidth: CGFloat,
        thumbnailSize: CGFloat,
        showFilename: Bool,
        showImageSize: Bool,
        showExtensions: Bool,
        basenamesNeedingExtensions: Set<String>,
        currentImagePath: String?
    ) -> Result {
        computeSectionedGridLayout(
            paths: paths,
            sectionStarts: sections.map(\.startIndex),
            separatorLabels: sections.map(\.sectionKey),
            duplicateSeparatorLine: false,
            viewportWidth: viewportWidth,
            thumbnailSize: thumbnailSize,
            showFilename: showFilename,
            showImageSize: showImageSize,
            showExtensions: showExtensions,
            basenamesNeedingExtensions: basenamesNeedingExtensions,
            displayStyle: .basename,
            currentImagePath: currentImagePath,
            sectionIndexForPath: { pathIndex, sectionStarts, pathCount in
                exifSectionIndex(for: pathIndex, sectionStarts: sectionStarts, pathCount: pathCount)
            },
            sectionContainsActive: { pathIndex, sectionIndex, sectionStarts, pathCount in
                guard pathIndex >= 0, sectionIndex < sectionStarts.count else { return false }
                let start = sectionStarts[sectionIndex]
                let end = sectionIndex + 1 < sectionStarts.count ? sectionStarts[sectionIndex + 1] : pathCount
                return start <= pathIndex && pathIndex < end
            }
        )
    }

    private static func computeSectionedGridLayout(
        paths: [String],
        sectionStarts: [Int],
        separatorLabels: [String?],
        duplicateSeparatorLine: Bool,
        viewportWidth: CGFloat,
        thumbnailSize: CGFloat,
        showFilename: Bool,
        showImageSize: Bool,
        showExtensions: Bool,
        basenamesNeedingExtensions: Set<String>,
        displayStyle: ThumbnailFilenameOverlayDisplayStyle,
        currentImagePath: String?,
        sectionIndexForPath: (_ pathIndex: Int, _ sectionStarts: [Int], _ pathCount: Int) -> Int?,
        sectionContainsActive: (_ pathIndex: Int, _ sectionIndex: Int, _ sectionStarts: [Int], _ pathCount: Int) -> Bool
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
                let text: String
                switch displayStyle {
                case .basename:
                    text = ThumbnailLayout.overlayDisplayFilename(
                        for: path,
                        showExtensions: showExtensions,
                        basenamesNeedingExtensions: basenamesNeedingExtensions
                    )
                case .duplicatePath:
                    text = duplicateFilenameOverlay(for: path)
                }
                for part in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    let segment = String(part)
                    guard !segment.isEmpty else { continue }
                    maxCellTextWidth = max(maxCellTextWidth, measureAdvance(segment, font: font))
                }
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
        for (sepIndex, startIndex) in sectionStarts.enumerated() {
            sectionStartToSeparatorIndex[startIndex] = sepIndex
            let containsActive = sectionContainsActive(
                paths.firstIndex(of: currentImagePath ?? "") ?? -1,
                sepIndex,
                sectionStarts,
                paths.count
            )
            separators.append(
                SeparatorItem(
                    isDuplicateLine: duplicateSeparatorLine,
                    label: separatorLabels.indices.contains(sepIndex) ? separatorLabels[sepIndex] : nil,
                    isBold: containsActive
                )
            )
        }

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

            let overlay = ThumbnailFilenameOverlayService.overlay(
                for: path,
                cellWidth: min(thumbnailSize * 2, ThumbnailLayout.maxCellSize),
                showFilename: showFilename,
                showImageSize: showImageSize,
                showExtensions: showExtensions,
                basenamesNeedingExtensions: basenamesNeedingExtensions,
                displayStyle: displayStyle,
                wrapMode: .sectionedMax(thumbnailSize: Int(thumbnailSize.rounded(.up)))
            )
            overlayHeights[thumbIndex] = overlay.overlayHeight
            wrappedLines[thumbIndex] = overlay.wrappedLines

            if col == 0, thumbIndex > 0, sectionStartToSeparatorIndex[thumbIndex] == nil {
                let prevIndex = thumbIndex - 1
                if sectionIndexForPath(prevIndex, sectionStarts, paths.count)
                    == sectionIndexForPath(thumbIndex, sectionStarts, paths.count) {
                    yOffset += spacing
                }
            }

            let x = xOffset + CGFloat(col) * (cellWidth + sectionedColumnSpacing)
            let rowH = rectSize + overlay.overlayHeight
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
            wrappedLines: wrappedLines,
            rowLayout: RowLayout(indexToRow: indexToRow, rowToIndices: rowToIndices)
        )
    }

    private static func exifSectionIndex(for pathIndex: Int, sectionStarts: [Int], pathCount: Int) -> Int? {
        guard pathIndex >= 0 else { return nil }
        var result: Int?
        for (idx, start) in sectionStarts.enumerated() {
            if start <= pathIndex {
                result = idx
            }
        }
        return result
    }
}
