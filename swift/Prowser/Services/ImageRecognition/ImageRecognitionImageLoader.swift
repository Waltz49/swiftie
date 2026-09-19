import CoreGraphics
import Foundation
import ImageIO

/// Load pixels for CNN/CLIP (EXIF orientation applied — matches macOS Quick Look / Qt fallback paths in Python).
enum ImageRecognitionImageLoader {
    static func loadCGImage(path: String) -> CGImage? {
        guard let normalized = ImageRecognitionPath.normalize(path) else { return nil }
        let url = URL(fileURLWithPath: normalized)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let pixelWidth = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let pixelHeight = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let maxPixel = max(pixelWidth, pixelHeight, 1)
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
}
