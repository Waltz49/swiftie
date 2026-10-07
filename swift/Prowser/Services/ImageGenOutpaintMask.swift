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
        var px = max(0, min(x, cw - 1))
        var py = max(0, min(y, ch - 1))
        var pw = max(128, min(w, cw - px))
        var ph = max(128, min(h, ch - py))

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
        bgCtx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        bgCtx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))

        let resized = resizeImage(source, width: pw, height: ph)
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
        maskCtx.setFillColor(gray: 1, alpha: 1)
        maskCtx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
        maskCtx.setFillColor(gray: 0, alpha: 1)
        let rect = CGRect(x: left, y: ch - bottom, width: right - left, height: bottom - top)
        maskCtx.fill(rect)
        let mask = maskCtx.makeImage()!
        return (background, mask)
    }

    static func compositeMaskedRegionsForKleinEdit(background: CGImage, mask: CGImage) -> CGImage {
        let w = background.width
        let h = background.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return background }
        let fill = CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        ctx.setFillColor(fill)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(background, in: CGRect(x: 0, y: 0, width: w, height: h))
        // White mask regions → gray fill via masking
        guard let masked = applyMaskComposite(background: background, overlay: ctx.makeImage()!, mask: mask, keepMaskBlack: false) else {
            return background
        }
        return masked
    }

    static func applyExpandKeepMask(generated: CGImage, background: CGImage, mask: CGImage) -> CGImage {
        applyMaskComposite(background: background, overlay: generated, mask: mask, keepMaskBlack: true) ?? generated
    }

    private static func applyMaskComposite(
        background: CGImage,
        overlay: CGImage,
        mask: CGImage,
        keepMaskBlack: Bool
    ) -> CGImage? {
        let w = overlay.width
        let h = overlay.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.draw(overlay, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.saveGState()
        if keepMaskBlack {
            ctx.clip(to: CGRect(x: 0, y: 0, width: w, height: h), mask: invertMask(mask))
        } else {
            ctx.clip(to: CGRect(x: 0, y: 0, width: w, height: h), mask: mask)
        }
        ctx.draw(background, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.restoreGState()
        return ctx.makeImage()
    }

    private static func invertMask(_ mask: CGImage) -> CGImage {
        let w = mask.width
        let h = mask.height
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return mask }
        ctx.draw(mask, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return mask }
        let ptr = data.bindMemory(to: UInt8.self, capacity: w * h)
        for i in 0..<(w * h) {
            ptr[i] = ptr[i] < 128 ? 255 : 0
        }
        return ctx.makeImage() ?? mask
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

    static func loadCGImage(path: String) -> CGImage? {
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
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
