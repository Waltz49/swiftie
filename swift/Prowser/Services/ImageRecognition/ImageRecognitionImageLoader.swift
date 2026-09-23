import CoreGraphics
import Foundation
import ImageIO

/// Load pixels for CNN/CLIP (EXIF orientation applied — matches macOS Quick Look / Qt fallback paths in Python).
enum ImageRecognitionImageLoader {
    /// - Parameter maxPixelSize: When set, longest edge is capped (ImageIO thumbnail decode). Used for face scanning downscale.
    static func loadCGImage(path: String, maxPixelSize: Int? = nil) -> CGImage? {
        guard let normalized = ImageRecognitionPath.normalize(path) else { return nil }
        let url = URL(fileURLWithPath: normalized)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let pixelWidth = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let pixelHeight = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let naturalMax = max(pixelWidth, pixelHeight, 1)
        let maxPixel: Int
        if let cap = maxPixelSize, cap > 0 {
            maxPixel = min(naturalMax, cap)
        } else {
            maxPixel = naturalMax
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        if let oriented = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
            return oriented
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Display-oriented width/height from EXIF (no full pixel decode). Matches thumbnail-with-transform sizing.
    static func orientedPixelSize(path: String) -> (width: Int, height: Int)? {
        guard let normalized = ImageRecognitionPath.normalize(path) else { return nil }
        let url = URL(fileURLWithPath: normalized)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        var width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        var height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0 else { return nil }
        if let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue {
            switch orientation {
            case 5, 6, 7, 8:
                swap(&width, &height)
            default:
                break
            }
        }
        return (width, height)
    }
}
