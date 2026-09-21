import CoreGraphics
import Foundation

enum ThumbnailTransparencyCompositor {
    /// Match Python `pil_to_qpixmap(..., preserve_alpha=False)` for thumbnail generation.
    static func compositeOntoCheckerboardIfNeeded(_ image: CGImage) -> CGImage {
        guard cgImageHasAlpha(image) else { return image }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return image }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        TransparencyCheckerboard.draw(in: rect, context: context)
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }

    private static func cgImageHasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            return true
        }
    }
}
