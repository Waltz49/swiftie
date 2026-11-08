import AppKit
import CoreGraphics
import Foundation

/// Port of `imagegen_plugins/outpaint_mask.py` (expand / Klein edit compositing).
enum ImageGenOutpaintMask {
    static func clampOutpaintDims(width: Int, height: Int, maxSide: Int) -> (Int, Int) {
        var w = max(128, min(maxSide, width))
        var h = max(128, min(maxSide, height))
        w -= w % 32
        h -= h % 32
        return (max(128, w), max(128, h))
    }

    static func prepareImageAndMaskAtRect(
        source: CGImage,
        canvasW: Int,
        canvasH: Int,
        x: Int,
        y: Int,
        w: Int,
        h: Int,
        overlapPercentage: Int
    ) -> (background: CGImage, mask: CGImage) {
        let cw = canvasW
        let ch = canvasH
        let px = max(0, min(x, cw - 1))
        let py = max(0, min(y, ch - 1))
        let pw = max(128, min(w, cw - px))
        let ph = max(128, min(h, ch - py))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let bgCtx = CGContext(
            data: nil,
            width: cw,
            height: ch,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            fatalError("CGContext")
        }
        bgCtx.setShouldAntialias(false)
        bgCtx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        bgCtx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
        let resized = resizeImage(source, width: pw, height: ph)
        bgCtx.interpolationQuality = .high
        bgCtx.draw(resized, in: CGRect(x: px, y: ch - py - ph, width: pw, height: ph))
        let background = bgCtx.makeImage()!

        let overlapX = max(1, Int(Double(pw) * Double(overlapPercentage) / 100))
        let overlapY = max(1, Int(Double(ph) * Double(overlapPercentage) / 100))
        let whiteGaps = 2
        let left = max(px + whiteGaps, px + overlapX)
        let right = min(px + pw - whiteGaps, px + pw - overlapX)
        let top = max(py + whiteGaps, py + overlapY)
        let bottom = min(py + ph - whiteGaps, py + ph - overlapY)

        guard let maskCtx = CGContext(
            data: nil,
            width: cw,
            height: ch,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            fatalError("mask ctx")
        }
        maskCtx.setShouldAntialias(false)
        maskCtx.interpolationQuality = .none
        maskCtx.setFillColor(gray: 1, alpha: 1)
        maskCtx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
        maskCtx.setFillColor(gray: 0, alpha: 1)
        maskCtx.fill(CGRect(x: left, y: ch - bottom, width: right - left, height: bottom - top))
        let mask = maskCtx.makeImage()!
        return (background, mask)
    }

    /// White mask → neutral gray. Black mask → original. Matches PIL ``Image.composite(fill, bg, mask)``.
    static func compositeMaskedRegionsForKleinEdit(background: CGImage, mask: CGImage) -> CGImage {
        let width = background.width
        let height = background.height
        let maskImage = fitted(mask, width: width, height: height)
        let bg = topLeftRGBA(background)
        let m = topLeftGray(maskImage)
        var out = bg
        for i in 0..<(width * height) {
            let coverage = Int(m[i])
            let keep = 255 - coverage
            let o = i * 4
            out[o] = UInt8((128 * coverage + Int(bg[o]) * keep) / 255)
            out[o + 1] = UInt8((128 * coverage + Int(bg[o + 1]) * keep) / 255)
            out[o + 2] = UInt8((128 * coverage + Int(bg[o + 2]) * keep) / 255)
            out[o + 3] = 255
        }
        return imageFromTopLeftRGBA(out, width: width, height: height)
    }

    private static func fitted(_ image: CGImage, width: Int, height: Int) -> CGImage {
        if image.width == width, image.height == height { return image }
        return resizeImage(image, width: width, height: height)
    }

    /// Row 0 is the top of the image, matching PIL. Device Gray masks must not use the RGB flip path.
    private static func topLeftGray(_ image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return pixels }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    /// Row 0 is the top of the image, matching PIL.
    private static func topLeftRGBA(_ image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return pixels }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private static func imageFromTopLeftRGBA(_ pixels: [UInt8], width: Int, height: Int) -> CGImage {
        let rowBytes = width * 4
        guard pixels.count >= rowBytes * height else {
            return blankImage(width: max(1, width), height: max(1, height))
        }
        // ``pixels`` is top-left row-major (PIL / ``topLeftRGBA``). CG bitmap contexts use bottom-left rows.
        var buffer = [UInt8](repeating: 0, count: rowBytes * height)
        for row in 0..<height {
            let src = row * rowBytes
            let dst = (height - 1 - row) * rowBytes
            buffer.replaceSubrange(dst..<(dst + rowBytes), with: pixels[src..<(src + rowBytes)])
        }
        guard let ctx = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: rowBytes,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = ctx.makeImage() else {
            return blankImage(width: max(1, width), height: max(1, height))
        }
        return image
    }

    private static func blankImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    static func resizeImagePublic(_ image: CGImage, width: Int, height: Int) -> CGImage {
        resizeImage(image, width: width, height: height)
    }

    private static func resizeImage(_ image: CGImage, width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? image
    }

    /// Source photos for expand placement (matches expand canvas / ``ImageDisplayLoader``).
    static func loadSourceCGImage(path: String) -> CGImage? {
        if let cg = ImageRecognitionImageLoader.loadCGImage(path: path) { return cg }
        return ImageDisplayLoader.orientedCGImage(for: path)
    }

    /// PNG/raster files written by imagegen (no EXIF); avoids ``NSImage`` point-size vs pixel mismatch.
    static func loadRasterCGImage(path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func loadCGImage(path: String) -> CGImage? {
        loadRasterCGImage(path: path)
            ?? loadSourceCGImage(path: path)
    }

    /// Debug: sample RGB at top-left coordinates (matches expand placement / PIL).
    static func debugTopLeftRGBSample(_ image: CGImage, x: Int, yTop: Int) -> [Int] {
        let rgba = topLeftRGBA(image)
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return [-1, -1, -1] }
        let sx = min(max(0, x), width - 1)
        let sy = min(max(0, yTop), height - 1)
        let index = (sy * width + sx) * 4
        guard index + 2 < rgba.count else { return [-1, -1, -1] }
        return [Int(rgba[index]), Int(rgba[index + 1]), Int(rgba[index + 2])]
    }

    @discardableResult
    static func savePNG(_ image: CGImage, path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }
}
