import AppKit
import ImageIO

/// Full-size browse decoding (ImageIO + EXIF orientation).
enum BrowseImageLoader {
    static func loadImage(from path: String, ignoreExifRotation: Bool) -> NSImage? {
        if let image = decodeImage(at: path, ignoreExifRotation: ignoreExifRotation) {
            return image
        }
        if PhotosLibraryBrowseLoader.isPhotosLibraryPath(path) {
            return PhotosLibraryBrowseLoader.loadImage(from: path)
        }
        return loadImageViaTemporaryCopy(from: path, ignoreExifRotation: ignoreExifRotation)
    }

    /// Copy out of `.photoslibrary` when ImageIO cannot decode in place (TCC / package paths).
    static func loadImageViaTemporaryCopy(from path: String, ignoreExifRotation: Bool) -> NSImage? {
        let src = URL(fileURLWithPath: path)
        let ext = src.pathExtension.isEmpty ? "jpg" : src.pathExtension
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("prowser-browse-\(UUID().uuidString).\(ext)")
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: src, to: dest)
            defer { try? FileManager.default.removeItem(at: dest) }
            return decodeImage(at: dest.path, ignoreExifRotation: ignoreExifRotation)
        } catch {
            return nil
        }
    }

    private static func decodeImage(at path: String, ignoreExifRotation: Bool) -> NSImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url, sourceOptions as CFDictionary) else {
            return NSImage(contentsOfFile: path)
        }

        if !ignoreExifRotation,
           let cgImage = orientedFullSizeImage(from: source, ignoreExifRotation: ignoreExifRotation) {
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }

        let imageOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if let cgImage = CGImageSourceCreateImageAtIndex(source, 0, imageOptions as CFDictionary) {
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }

        if let cgImage = thumbnailDecode(from: source, maxPixel: 16_384, ignoreExifRotation: ignoreExifRotation) {
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }

        if let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe]),
           let dataSource = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary),
           let cgImage = thumbnailDecode(from: dataSource, maxPixel: 16_384, ignoreExifRotation: ignoreExifRotation) {
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }

        return NSImage(contentsOfFile: path)
    }

    /// Same strategy as `ThumbnailCache` — required for some Photos Library `originals/` files.
    private static func thumbnailDecode(
        from source: CGImageSource,
        maxPixel: Int,
        ignoreExifRotation: Bool
    ) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: !ignoreExifRotation,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func orientedFullSizeImage(from source: CGImageSource, ignoreExifRotation: Bool) -> CGImage? {
        let propertyOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, propertyOptions as CFDictionary) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? Int,
           let height = props[kCGImagePropertyPixelHeight] as? Int,
           width > 0, height > 0 {
            return thumbnailDecode(from: source, maxPixel: max(width, height), ignoreExifRotation: ignoreExifRotation)
        }
        return thumbnailDecode(from: source, maxPixel: 16_384, ignoreExifRotation: ignoreExifRotation)
    }
}
