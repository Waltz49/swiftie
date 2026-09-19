import CoreGraphics
import Foundation
import ImageIO

enum CLIPPreprocessor {
    private static let mean: [Float] = [0.48145466, 0.4578275, 0.40821073]
    private static let std: [Float] = [0.26862954, 0.26130258, 0.27577711]

    static func makeImageInput(from path: String) -> [Float]? {
        guard let cgImage = ImageRecognitionImageLoader.loadCGImage(path: path) else { return nil }
        return makeImageInput(from: cgImage)
    }

    static func makeImageInput(from cgImage: CGImage) -> [Float]? {
        let resized = ImageNetPreprocessor.resizePublic(cgImage, shortSide: 224)
        guard let cropped = centerCrop(resized, size: 224) else { return nil }
        return normalizedCHW(cropped)
    }

    private static func centerCrop(_ image: CGImage, size: Int) -> CGImage? {
        let w = image.width
        let h = image.height
        let x = max(0, (w - size) / 2)
        let y = max(0, (h - size) / 2)
        return image.cropping(to: CGRect(x: x, y: y, width: min(size, w), height: min(size, h)))
    }

    private static func normalizedCHW(_ image: CGImage) -> [Float]? {
        let w = image.width
        let h = image.height
        let bytesPerPixel = 4
        let bytesPerRow = w * bytesPerPixel
        var raw = [UInt8](repeating: 0, count: h * bytesPerRow)
        guard let ctx = CGContext(
            data: &raw,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out = [Float](repeating: 0, count: 3 * w * h)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let i = (y * w + x) * bytesPerPixel
                let r = Float(raw[i]) / 255
                let g = Float(raw[i + 1]) / 255
                let b = Float(raw[i + 2]) / 255
                let offset = y * w + x
                out[offset] = (r - mean[0]) / std[0]
                out[w * h + offset] = (g - mean[1]) / std[1]
                out[2 * w * h + offset] = (b - mean[2]) / std[2]
            }
        }
        return out
    }
}

extension ImageNetPreprocessor {
    static func resizePublic(_ image: CGImage, shortSide: Int) -> CGImage {
        let w = image.width
        let h = image.height
        let scale = Float(shortSide) / Float(min(w, h))
        let newW = Int(Float(w) * scale)
        let newH = Int(Float(h) * scale)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? image
    }
}
