import AppKit
import Foundation

enum ThumbnailFilenameOverlayDisplayStyle: Hashable {
    case basename
    case duplicatePath
}

enum ThumbnailFilenameWrapMode: Hashable {
    /// Standard grid / reference graph: wrap at cell inner width.
    case cellWidth
    /// Sectioned grid: wrap up to min(thumbnailSize * 2, maxCellSize).
    case sectionedMax(thumbnailSize: Int)
}

struct ThumbnailFilenameOverlay: Equatable {
    let wrappedLines: [String]
    let overlayHeight: CGFloat
}

/// Shared filename/size overlay layout (port of Python `_get_overlay_height_for_thumbnail` + `_draw_filename_overlay`).
enum ThumbnailFilenameOverlayService {
    static let overlayFont: NSFont = NSFont(name: "Arial", size: 14) ?? NSFont.systemFont(ofSize: 14)
    private static let overlaySpacing: CGFloat = 4
    private static let overlayPadding: CGFloat = 4

    /// Conservative estimate for auto thumbnail sizing (Python `_get_overlay_height`).
    static func conservativeOverlayHeight(showFilename: Bool, showImageSize: Bool) -> CGFloat {
        guard showFilename || showImageSize else { return 0 }
        var numLines = showFilename ? 1 : 0
        if showImageSize { numLines += 1 }
        return overlaySpacing + CGFloat(numLines) * ThumbnailLayout.labelHeight + overlayPadding
    }

    static func lineWrapWidth(cellWidth: CGFloat, wrapMode: ThumbnailFilenameWrapMode) -> CGFloat {
        switch wrapMode {
        case .cellWidth:
            return max(1, cellWidth - 8)
        case .sectionedMax(let thumbnailSize):
            let maxAllowed = min(CGFloat(thumbnailSize) * 2, ThumbnailLayout.maxCellSize)
            return max(1, maxAllowed - 8)
        }
    }

    static func overlay(
        for path: String,
        cellWidth: CGFloat,
        showFilename: Bool,
        showImageSize: Bool,
        showExtensions: Bool,
        basenamesNeedingExtensions: Set<String>,
        displayStyle: ThumbnailFilenameOverlayDisplayStyle,
        wrapMode: ThumbnailFilenameWrapMode,
        cache: ThumbnailFilenameOverlayCache = .shared
    ) -> ThumbnailFilenameOverlay {
        let key = ThumbnailFilenameOverlayCache.Key(
            path: path,
            cellWidth: Int(cellWidth.rounded(.up)),
            showFilename: showFilename,
            showImageSize: showImageSize,
            showExtensions: showExtensions,
            displayStyle: displayStyle,
            wrapMode: wrapMode
        )
        if let cached = cache.lookup(key) {
            return cached
        }
        cache.recordCompute()
        let result = computeOverlay(
            for: path,
            cellWidth: cellWidth,
            showFilename: showFilename,
            showImageSize: showImageSize,
            showExtensions: showExtensions,
            basenamesNeedingExtensions: basenamesNeedingExtensions,
            displayStyle: displayStyle,
            wrapMode: wrapMode
        )
        cache.store(result, for: key)
        return result
    }

    static func computeOverlay(
        for path: String,
        cellWidth: CGFloat,
        showFilename: Bool,
        showImageSize: Bool,
        showExtensions: Bool,
        basenamesNeedingExtensions: Set<String>,
        displayStyle: ThumbnailFilenameOverlayDisplayStyle,
        wrapMode: ThumbnailFilenameWrapMode
    ) -> ThumbnailFilenameOverlay {
        guard showFilename || showImageSize else {
            return ThumbnailFilenameOverlay(wrappedLines: [], overlayHeight: 0)
        }

        var wrappedLines: [String] = []
        if showFilename {
            let displayText: String
            switch displayStyle {
            case .basename:
                displayText = ThumbnailLayout.overlayDisplayFilename(
                    for: path,
                    showExtensions: showExtensions,
                    basenamesNeedingExtensions: basenamesNeedingExtensions
                )
            case .duplicatePath:
                displayText = ThumbnailSectionedLayout.duplicateFilenameOverlay(for: path)
            }
            wrappedLines = wrappedLinesForDisplayText(
                displayText,
                cellWidth: cellWidth,
                wrapMode: wrapMode
            )
        }
        if showImageSize {
            wrappedLines.append("0x0")
        }
        guard !wrappedLines.isEmpty else {
            return ThumbnailFilenameOverlay(wrappedLines: [], overlayHeight: 0)
        }
        let height = overlaySpacing
            + CGFloat(wrappedLines.count) * ThumbnailLayout.labelHeight
            + overlayPadding
        return ThumbnailFilenameOverlay(wrappedLines: wrappedLines, overlayHeight: height)
    }

    static func wrappedLinesForDisplayText(
        _ displayText: String,
        cellWidth: CGFloat,
        wrapMode: ThumbnailFilenameWrapMode
    ) -> [String] {
        let inner = lineWrapWidth(cellWidth: cellWidth, wrapMode: wrapMode)
        switch wrapMode {
        case .sectionedMax:
            let flatWidth = (displayText.replacingOccurrences(of: "\n", with: " ") as NSString)
                .size(withAttributes: [.font: overlayFont]).width
            if flatWidth > inner + 8 {
                return displayText
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map(String.init)
                    .filter { !$0.isEmpty }
                    .flatMap { ThumbnailSectionedLayout.wrapFilenameText($0, maxWidth: inner, font: overlayFont) }
            }
            return displayText
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { !$0.isEmpty }
        case .cellWidth:
            return ThumbnailSectionedLayout.wrapFilenameText(displayText, maxWidth: inner, font: overlayFont)
        }
    }

    /// Replace layout placeholder with real dimensions for drawing.
    static func linesForDrawing(
        overlay: ThumbnailFilenameOverlay,
        path: String,
        showImageSize: Bool,
        dimensionText: String?
    ) -> [String] {
        guard !overlay.wrappedLines.isEmpty else { return [] }
        var lines = overlay.wrappedLines
        if showImageSize, let dimensionText, let last = lines.last, last == "0x0" {
            lines[lines.count - 1] = dimensionText
        } else if showImageSize, let dimensionText {
            lines.append(dimensionText)
        }
        return lines
    }
}

final class ThumbnailFilenameOverlayCache {
    static let shared = ThumbnailFilenameOverlayCache()

    struct Key: Hashable {
        var path: String
        var cellWidth: Int
        var showFilename: Bool
        var showImageSize: Bool
        var showExtensions: Bool
        var displayStyle: ThumbnailFilenameOverlayDisplayStyle
        var wrapMode: ThumbnailFilenameWrapMode
    }

    private var storage: [Key: ThumbnailFilenameOverlay] = [:]
    private(set) var computeCount = 0

    func clear() {
        storage.removeAll()
        computeCount = 0
    }

    func lookup(_ key: Key) -> ThumbnailFilenameOverlay? {
        storage[key]
    }

    func store(_ overlay: ThumbnailFilenameOverlay, for key: Key) {
        storage[key] = overlay
    }

    func recordCompute() {
        computeCount += 1
    }
}
