import CoreGraphics
import Foundation

/// Browse viewport → source-pixel mapping for wallpaper zoom export.
/// Port of `browse_view_handler.get_visible_source_rect`.
enum BrowseWallpaperGeometry {
    static let screenAspectMatchTolerance = 0.002

    static func viewportAspectMatchesScreen(
        viewportWidth: CGFloat,
        viewportHeight: CGFloat,
        screenWidth: CGFloat,
        screenHeight: CGFloat,
        tolerance: CGFloat = screenAspectMatchTolerance
    ) -> Bool {
        guard viewportWidth >= 2, viewportHeight >= 2, screenWidth > 0, screenHeight > 0 else { return false }
        let viewportRatio = viewportWidth / viewportHeight
        let screenRatio = screenWidth / screenHeight
        return abs(viewportRatio - screenRatio) < tolerance
    }

    /// Maps the intersection of the painted image rect with the browse viewport to layout/source pixels.
    /// Used for wallpaper enlargement when the viewport matches screen aspect (⇧W workflow).
    static func visibleSourceRectFromImageDrawRect(
        viewportWidth: CGFloat,
        viewportHeight: CGFloat,
        imageDrawRect: CGRect,
        scaleFactor: CGFloat,
        sourceWidth: CGFloat,
        sourceHeight: CGFloat
    ) -> CGRect? {
        guard viewportWidth >= 2, viewportHeight >= 2,
              sourceWidth > 0, sourceHeight > 0, scaleFactor > 0,
              imageDrawRect.width > 0, imageDrawRect.height > 0
        else { return nil }

        let viewport = CGRect(x: 0, y: 0, width: viewportWidth, height: viewportHeight)
        let visible = viewport.intersection(imageDrawRect)
        guard visible.width > 0, visible.height > 0 else { return nil }

        let scaledOffsetX = visible.minX - imageDrawRect.minX
        let scaledOffsetY = visible.minY - imageDrawRect.minY

        var sourceX = scaledOffsetX / scaleFactor
        var sourceY = scaledOffsetY / scaleFactor
        var sourceW = visible.width / scaleFactor
        var sourceH = visible.height / scaleFactor

        sourceX = max(0, min(sourceWidth, sourceX))
        sourceY = max(0, min(sourceHeight, sourceY))
        sourceW = max(1, min(sourceWidth - sourceX, sourceW))
        sourceH = max(1, min(sourceHeight - sourceY, sourceH))

        return CGRect(x: sourceX, y: sourceY, width: sourceW, height: sourceH)
    }

    static func visibleSourceRect(
        viewportWidth: CGFloat,
        viewportHeight: CGFloat,
        sourceWidth: CGFloat,
        sourceHeight: CGFloat,
        scaleFactor: CGFloat,
        scrollX: CGFloat,
        scrollY: CGFloat
    ) -> CGRect? {
        guard viewportWidth >= 2, viewportHeight >= 2,
              sourceWidth > 0, sourceHeight > 0, scaleFactor > 0
        else { return nil }

        let srcW = sourceWidth
        let srcH = sourceHeight
        let scaledW = srcW * scaleFactor
        let scaledH = srcH * scaleFactor
        let canPan = scaledW > viewportWidth + 1 || scaledH > viewportHeight + 1

        if !canPan {
            return CGRect(x: 0, y: 0, width: srcW, height: srcH)
        }

        // Matches ``BrowseImageNSView.imageDrawRect`` (centered layout box minus scroll offset).
        let srcX = max(0, (scaledW - viewportWidth) / 2 + scrollX)
        let srcY = max(0, (scaledH - viewportHeight) / 2 + scrollY)
        let srcWidth = min(scaledW - srcX, viewportWidth)
        let srcHeight = min(scaledH - srcY, viewportHeight)

        let scale = scaleFactor
        var sourceX = Int(srcX / scale)
        var sourceY = Int(srcY / scale)
        var sourceWidth = Int(srcWidth / scale)
        var sourceHeight = Int(srcHeight / scale)

        let intSrcW = Int(srcW)
        let intSrcH = Int(srcH)
        sourceX = max(0, min(intSrcW - 1, sourceX))
        sourceY = max(0, min(intSrcH - 1, sourceY))
        sourceWidth = max(1, min(intSrcW - sourceX, sourceWidth))
        sourceHeight = max(1, min(intSrcH - sourceY, sourceHeight))

        return CGRect(
            x: CGFloat(sourceX),
            y: CGFloat(sourceY),
            width: CGFloat(sourceWidth),
            height: CGFloat(sourceHeight)
        )
    }
}