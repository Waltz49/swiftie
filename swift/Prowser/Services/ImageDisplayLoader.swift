import AppKit
import ImageIO

/// Display-oriented image loading with EXIF orientation applied.
enum ImageDisplayLoader {
    static func orientedImage(for path: String, maxPixelSize: Int = 4096) -> NSImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else {
            return NSImage(contentsOfFile: path)
        }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return NSImage(contentsOfFile: path)
        }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }

    static func draw(
        _ image: NSImage,
        in rect: NSRect,
        operation: NSCompositingOperation = .sourceOver
    ) {
        image.draw(
            in: rect,
            from: NSRect(origin: .zero, size: image.size),
            operation: operation,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }
}
