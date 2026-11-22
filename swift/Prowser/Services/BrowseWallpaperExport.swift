import AppKit
import CoreGraphics
import Foundation

/// Full-resolution wallpaper crop from layout-pixel space (session transforms baked in).
enum BrowseWallpaperExport {
    /// Layout-space top-left rect (same coordinates as ``BrowseImageSessionTransform`` layout bitmap).
    static func exportCroppedPNG(
        image: NSImage,
        transform: BrowseImageSessionTransform.State,
        layoutCrop: CGRect,
        tempDirectory: URL
    ) -> String? {
        let crop = layoutCrop.integral
        guard crop.width >= 1, crop.height >= 1 else { return nil }
        guard let layoutRep = renderLayoutBitmap(image: image, transform: transform) else { return nil }

        let cropW = max(1, Int(crop.width.rounded(.down)))
        let cropH = max(1, Int(crop.height.rounded(.down)))
        guard let cropRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: cropW,
            pixelsHigh: cropH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        cropRep.size = NSSize(width: crop.width, height: crop.height)

        guard let layoutCG = layoutRep.cgImage else { return nil }
        let fullH = CGFloat(layoutCG.height)
        // `layoutCrop` is top-left, Y down (browse flipped view). `CGImage` uses bottom-left origin.
        let cgCrop = CGRect(
            x: crop.minX,
            y: fullH - crop.maxY,
            width: crop.width,
            height: crop.height
        ).integral
        guard let croppedCG = layoutCG.cropping(to: cgCrop) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let cropContext = NSGraphicsContext(bitmapImageRep: cropRep)
        NSGraphicsContext.current = cropContext
        guard let ctx = cropContext?.cgContext else { return nil }

        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(cropH))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        let croppedImage = NSImage(cgImage: croppedCG, size: crop.size)
        croppedImage.draw(
            in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height),
            from: .zero,
            operation: .copy,
            fraction: 1.0,
            respectFlipped: true,
            hints: nil
        )
        ctx.restoreGState()

        guard let data = cropRep.representation(using: .png, properties: [:]) else { return nil }
        let url = tempDirectory.appendingPathComponent("prowser_wallpaper_zoom_\(UUID().uuidString).png")
        do {
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
            try data.write(to: url)
            return url.path
        } catch {
            return nil
        }
    }

    /// Pixels in a top-left layout bitmap (Y increasing downward), matching browse ``draw(_:)``.
    private static func renderLayoutBitmap(
        image: NSImage,
        transform: BrowseImageSessionTransform.State
    ) -> NSBitmapImageRep? {
        let layout = BrowseImageSessionTransform.layoutSize(for: image.size, transform: transform)
        let w = max(1, Int(layout.width.rounded(.down)))
        let h = max(1, Int(layout.height.rounded(.down)))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: w,
            pixelsHigh: h,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = layout

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let graphicsContext = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = graphicsContext
        guard let ctx = graphicsContext?.cgContext else { return nil }

        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        BrowseImageSessionTransform.applyVisualTransform(to: ctx, transform: transform)

        let contentRect = BrowseImageSessionTransform.localContentRect(contentSize: image.size)
        image.draw(
            in: contentRect,
            from: .zero,
            operation: .copy,
            fraction: 1.0,
            respectFlipped: true,
            hints: nil
        )
        ctx.restoreGState()

        return rep
    }
}