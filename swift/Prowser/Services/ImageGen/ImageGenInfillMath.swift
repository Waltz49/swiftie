import CoreGraphics
import AppKit
import Foundation

/// Port of ``outpaint_mask.fit_infill_paint_dims`` / ``fit_edit_output_dims`` and infill mask semantics.
enum ImageGenInfillMath {
    /// MFLUX fill infill model floor; upscale smaller working sizes before export/generation.
    static let infillModelMinimumSide = 512

    static func fitInfillPaintDims(width: Int, height: Int, maxSide: Int) -> (width: Int, height: Int) {
        let fitted = fitEditOutputDims(width: width, height: height, maxSide: maxSide, step: 16, minSide: 256)
        return ensureMinimumModelSide(
            width: fitted.width,
            height: fitted.height,
            minimumSide: infillModelMinimumSide,
            step: 16
        )
    }

    /// Upscale when min(width, height) is below ``infillModelMinimumSide`` (aspect preserved, step-aligned).
    static func ensureMinimumModelSide(
        width: Int,
        height: Int,
        minimumSide: Int = infillModelMinimumSide,
        step: Int = 16
    ) -> (width: Int, height: Int) {
        var w = width
        var h = height
        let minDim = min(w, h)
        guard minDim > 0, minDim < minimumSide else { return (w, h) }
        let scale = Double(minimumSide) / Double(minDim)
        w = max(minimumSide, Int(round(Double(w) * scale)))
        h = max(minimumSide, Int(round(Double(h) * scale)))
        let s = max(1, step)
        w = max(minimumSide, w - (w % s))
        h = max(minimumSide, h - (h % s))
        return (w, h)
    }

    static func fitEditOutputDims(
        width: Int,
        height: Int,
        maxSide: Int,
        step: Int = 16,
        minSide: Int = 128
    ) -> (width: Int, height: Int) {
        var w = width
        var h = height
        if w <= 0 || h <= 0 {
            let side = max(minSide, min(maxSide, step * 64))
            return (side, side)
        }
        let scale = min(1.0, Double(maxSide) / Double(max(w, h)))
        w = max(minSide, Int(round(Double(w) * scale)))
        h = max(minSide, Int(round(Double(h) * scale)))
        let s = max(1, step)
        w = max(minSide, w - (w % s))
        h = max(minSide, h - (h % s))
        return (w, h)
    }

    /// Pixelmator / paint mask: opaque = fill → MFLUX L (white = fill).
    static func maskToMfluxGrayscale(_ mask: CGImage) -> CGImage? {
        let w = mask.width
        let h = mask.height
        guard w > 0, h > 0 else { return nil }
        guard let rgba = ImageGenInfillMask.ensureRGBA(mask) else { return nil }
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let srcData = rgba.dataProvider?.data as Data? else {
            return nil
        }
        let src = [UInt8](srcData)
        guard let dst = ctx.data else { return nil }
        let dstBpr = ctx.bytesPerRow
        let ptr = dst.bindMemory(to: UInt8.self, capacity: dstBpr * h)
        let bpp = rgba.bitsPerPixel / 8
        let bpr = rgba.bytesPerRow
        for y in 0..<h {
            for x in 0..<w {
                let offset = y * bpr + x * bpp
                let alpha = bpp >= 4 ? src[offset + 3] : src[offset]
                ptr[y * dstBpr + x] = alpha > 127 ? 255 : 0
            }
        }
        return ctx.makeImage()
    }

    /// Convert MFLUX / Pixelmator mask file to paint canvas mask (white on transparent).
    static func pixelmatorMaskFileToPaintMask(_ path: String) -> CGImage? {
        guard let cg = ImageRecognitionImageLoader.loadCGImage(path: path) else { return nil }
        return mfluxMaskToPaintMask(cg)
    }

    static func mfluxMaskToPaintMask(_ mask: CGImage) -> CGImage? {
        let w = mask.width
        let h = mask.height
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        guard let gray = maskToMfluxGrayscale(mask) ?? (mask.colorSpace?.numberOfComponents == 1 ? mask : nil),
              let data = gray.dataProvider?.data as Data? else {
            return nil
        }
        let bytes = [UInt8](data)
        guard let outData = ctx.data else { return nil }
        let outBpr = ctx.bytesPerRow
        let out = outData.bindMemory(to: UInt8.self, capacity: outBpr * h)
        let bpr = gray.bytesPerRow
        for y in 0..<h {
            for x in 0..<w {
                let fill = bytes[y * bpr + x] > 127
                let i = y * outBpr + x * 4
                if fill {
                    out[i] = 255
                    out[i + 1] = 255
                    out[i + 2] = 255
                    out[i + 3] = 255
                } else {
                    out[i] = 0
                    out[i + 1] = 0
                    out[i + 2] = 0
                    out[i + 3] = 0
                }
            }
        }
        return ctx.makeImage()
    }

    static func paintMaskToPixelmatorRGBA(_ mask: CGImage) -> CGImage? {
        let w = mask.width
        let h = mask.height
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let rgba = ImageGenInfillMask.ensureRGBA(mask) else {
            return nil
        }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        guard let srcData = rgba.dataProvider?.data as Data?,
              let dst = ctx.data else { return nil }
        let src = [UInt8](srcData)
        let outBpr = ctx.bytesPerRow
        let out = dst.bindMemory(to: UInt8.self, capacity: outBpr * h)
        let bpp = rgba.bitsPerPixel / 8
        let bpr = rgba.bytesPerRow
        for y in 0..<h {
            for x in 0..<w {
                let offset = y * bpr + x * bpp
                let painted = bpp >= 4 ? src[offset + 3] > 0 : src[offset] > 0
                let i = y * outBpr + x * 4
                if painted {
                    out[i] = 255
                    out[i + 1] = 255
                    out[i + 2] = 255
                    out[i + 3] = 255
                }
            }
        }
        return ctx.makeImage()
    }
}

enum ImageGenInfillMask {
    /// Rasterize to premultiplied RGBA so mask pixels are readable (ImageIO thumbnails use premultiplied-first).
    static func ensureRGBA(_ image: CGImage) -> CGImage? {
        let w = image.width
        let h = image.height
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func emptyMask(width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    static func maskHasPaint(_ mask: CGImage?) -> Bool {
        guard let mask, let rgba = ensureRGBA(mask),
              let data = rgba.dataProvider?.data as Data? else { return false }
        let bpp = rgba.bitsPerPixel / 8
        let bpr = rgba.bytesPerRow
        let bytes = [UInt8](data)
        let h = rgba.height
        let w = rgba.width
        for y in 0..<h {
            for x in 0..<w {
                let offset = y * bpr + x * bpp
                if bpp >= 4, bytes[offset + 3] > 0 { return true }
            }
        }
        return false
    }
}

enum ImageGenInfillPathSemantics {
    static func isWorkingTempPath(_ path: String, tempRoot: String) -> Bool {
        let ap = URL(fileURLWithPath: path).standardizedFileURL.path
        if ap.isEmpty { return false }
        let normRoot = URL(fileURLWithPath: tempRoot).standardizedFileURL.path
        if !normRoot.isEmpty, ap == normRoot || ap.hasPrefix(normRoot + "/") {
            return true
        }
        let pixelmatorDir = (tempRoot as NSString).appendingPathComponent("pixelmator")
        let normPixel = URL(fileURLWithPath: pixelmatorDir).standardizedFileURL.path
        if ap == normPixel || ap.hasPrefix(normPixel + "/") { return true }
        let parent = (ap as NSString).deletingLastPathComponent
        return (parent as NSString).lastPathComponent.hasPrefix("imagegen-infill-")
    }
}

enum ImageGenEditorSettings {
    static let pixelmatorProName = "Pixelmator Pro"
    private static let pixelmatorProBundleID = "com.pixelmatorteam.pixelmator.x"

    static func isPixelmatorProEditor(_ appName: String) -> Bool {
        appName.trimmingCharacters(in: .whitespacesAndNewlines) == pixelmatorProName
    }

    static func isPixelmatorProInstalled() -> Bool {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: pixelmatorProBundleID) != nil {
            return true
        }
        let defaultPath = "/Applications/Pixelmator Pro.app"
        return FileManager.default.fileExists(atPath: defaultPath)
    }

    /// Infill refine UI: configured editor (Python parity) or Pixelmator Pro on disk.
    static func shouldShowInfillPixelmatorRefine(editorApp: String) -> Bool {
        isPixelmatorProEditor(editorApp) || isPixelmatorProInstalled()
    }
}
