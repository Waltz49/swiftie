import CoreGraphics
import Foundation
import ImageIO

/// EXIF/metadata when re-encoding images (convert format, screen copy). Port of Pillow `exif=` on save.
enum ImageReencodeMetadata {
    static func saveFormatName(for pathExtension: String) -> String? {
        switch pathExtension.lowercased() {
        case "jpg", "jpeg": return "JPEG"
        case "png": return "PNG"
        case "gif": return "GIF"
        case "bmp": return "BMP"
        case "webp": return "WEBP"
        case "tiff", "tif": return "TIFF"
        default: return nil
        }
    }

    static func orientedImage(from source: CGImageSource, ignoreExifRotation: Bool) -> CGImage? {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        if ignoreExifRotation {
            return image
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        guard let orientation = props[kCGImagePropertyOrientation] as? Int, orientation != 1 else {
            return image
        }
        return applyOrientation(image, orientation: orientation) ?? image
    }

    /// Copy ImageIO metadata from *source* for writing with *renderedImage* pixels.
    static func propertiesForSave(
        from source: CGImageSource,
        renderedImage: CGImage,
        ignoreExifRotation: Bool
    ) -> [CFString: Any] {
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let bakedOrientation = !ignoreExifRotation
        if bakedOrientation {
            properties[kCGImagePropertyOrientation] = 1
            properties[kCGImagePropertyPixelWidth] = renderedImage.width
            properties[kCGImagePropertyPixelHeight] = renderedImage.height
            if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exif[kCGImagePropertyOrientation] = 1
                exif[kCGImagePropertyExifPixelXDimension] = renderedImage.width
                exif[kCGImagePropertyExifPixelYDimension] = renderedImage.height
                properties[kCGImagePropertyExifDictionary] = exif
            }
        }
        return properties
    }

    static func destinationEncodeProperties(saveFormat: String, base: [CFString: Any]) -> [CFString: Any] {
        var props = base
        switch saveFormat {
        case "JPEG":
            props[kCGImageDestinationLossyCompressionQuality] = 0.95
        case "PNG":
            props[kCGImagePropertyPNGCompressionFilter] = 6
        case "WEBP":
            if let alpha = base[kCGImagePropertyHasAlpha] as? Bool, alpha {
                props[kCGImageDestinationLossyCompressionQuality] = 1.0
            } else {
                props[kCGImageDestinationLossyCompressionQuality] = 0.95
            }
        default:
            break
        }
        return props
    }

    /// Flatten alpha onto white for JPEG output (Python convert_format RGBA handling).
    static func imageHasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            return true
        }
    }

    static func imageForJPEGSave(_ image: CGImage) -> CGImage {
        guard imageHasAlpha(image) else { return image }
        let width = image.width
        let height = image.height
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return image
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    static func exifTiffForWebP(from properties: [CFString: Any]) -> Data? {
        guard properties[kCGImagePropertyExifDictionary] != nil
            || properties[kCGImagePropertyTIFFDictionary] != nil else {
            return nil
        }
        return try? ExifService.exifTiffBytes(fromImageProperties: properties)
    }

    private static func applyOrientation(_ image: CGImage, orientation: Int) -> CGImage? {
        let width = image.width
        let height = image.height
        var transform = CGAffineTransform.identity
        var drawWidth = width
        var drawHeight = height

        switch orientation {
        case 2:
            transform = transform.translatedBy(x: CGFloat(width), y: 0).scaledBy(x: -1, y: 1)
        case 3:
            transform = transform.translatedBy(x: CGFloat(width), y: CGFloat(height)).rotated(by: .pi)
        case 4:
            transform = transform.translatedBy(x: 0, y: CGFloat(height)).scaledBy(x: 1, y: -1)
        case 5:
            transform = transform.translatedBy(x: CGFloat(height), y: 0).rotated(by: .pi / 2).scaledBy(x: -1, y: 1)
            drawWidth = height
            drawHeight = width
        case 6:
            transform = transform.translatedBy(x: 0, y: 0).rotated(by: .pi / 2)
            drawWidth = height
            drawHeight = width
        case 7:
            transform = transform.translatedBy(x: CGFloat(height), y: CGFloat(width)).rotated(by: -.pi / 2).scaledBy(x: -1, y: 1)
            drawWidth = height
            drawHeight = width
        case 8:
            transform = transform.translatedBy(x: 0, y: CGFloat(width)).rotated(by: -.pi / 2)
            drawWidth = height
            drawHeight = width
        default:
            return image
        }

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: drawWidth,
            height: drawHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        context.concatenate(transform)
        let drawRect: CGRect
        if orientation >= 5 && orientation <= 8 {
            drawRect = CGRect(x: 0, y: 0, width: height, height: width)
        } else {
            drawRect = CGRect(x: 0, y: 0, width: width, height: height)
        }
        context.draw(image, in: drawRect)
        return context.makeImage()
    }
}
