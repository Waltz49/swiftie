import CoreGraphics
import Foundation
import ImageIO

/// Fast same-format resize core: one open, one decode, one render, one encoded write.
enum RasterImagePipeline {
    struct OpenedFile {
        let source: CGImageSource
        let uti: CFString
        let saveFormat: String
        let properties: [CFString: Any]
        let webpExifChunk: Data?

        var rawWidth: Int {
            (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        }

        var rawHeight: Int {
            (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        }

        var orientation: Int {
            (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        }

        var hasAlpha: Bool {
            (properties[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue ?? false
        }

        func displayedSize(ignoreExifRotation: Bool) -> (width: Int, height: Int) {
            if !ignoreExifRotation, (5 ... 8).contains(orientation) {
                return (rawHeight, rawWidth)
            }
            return (rawWidth, rawHeight)
        }

        /// We preserve the source orientation tag, so an oriented target must be transposed on disk.
        func rawOutputSize(
            displayedWidth: Int,
            displayedHeight: Int,
            ignoreExifRotation: Bool
        ) -> (width: Int, height: Int) {
            if !ignoreExifRotation, (5 ... 8).contains(orientation) {
                return (displayedHeight, displayedWidth)
            }
            return (displayedWidth, displayedHeight)
        }
    }

    enum PipelineError: LocalizedError {
        case decodeFailed
        case renderFailed
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .decodeFailed: return "Could not decode image"
            case .renderFailed: return "Could not resize image"
            case .saveFailed: return "Could not save image"
            }
        }
    }

    private static let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]

    /// WebP bytes are read once and shared by ImageIO decode and EXIF extraction.
    static func open(path: String) -> OpenedFile? {
        let url = URL(fileURLWithPath: path)
        guard let saveFormat = ImageReencodeMetadata.saveFormatName(for: url.pathExtension) else {
            return nil
        }

        let source: CGImageSource
        let exifChunk: Data?
        if saveFormat == "WEBP" {
            guard let data = try? Data(contentsOf: url),
                  let dataSource = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary)
            else {
                return nil
            }
            source = dataSource
            exifChunk = WebPImageWriter.extractExifChunk(from: data)
        } else {
            guard let urlSource = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
                return nil
            }
            source = urlSource
            exifChunk = nil
        }

        guard let uti = CGImageSourceGetType(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                sourceOptions as CFDictionary
              ) as? [CFString: Any]
        else {
            return nil
        }
        return OpenedFile(
            source: source,
            uti: uti,
            saveFormat: saveFormat,
            properties: properties,
            webpExifChunk: exifChunk
        )
    }

    /// Decode raw pixels. Orientation remains in metadata and is not rendered into a second buffer.
    static func decode(_ opened: OpenedFile) throws -> CGImage {
        guard let image = CGImageSourceCreateImageAtIndex(
            opened.source,
            0,
            sourceOptions as CFDictionary
        ) else {
            throw PipelineError.decodeFailed
        }
        return image
    }

    static func outputColorSpace(for image: CGImage, opened: OpenedFile) -> CGColorSpace {
        if opened.saveFormat != "WEBP",
           let sourceColorSpace = image.colorSpace,
           sourceColorSpace.model == .rgb {
            return sourceColorSpace
        }
        return CGColorSpaceCreateDeviceRGB()
    }

    /// One CGContext draw performs resize, crop/letterbox, and alpha handling.
    static func render(
        image: CGImage,
        width: Int,
        height: Int,
        drawRect: CGRect? = nil,
        interpolationQuality: CGInterpolationQuality,
        useAlphaChannel: Bool,
        colorSpace: CGColorSpace,
        background: CGColor
    ) throws -> CGImage {
        let alphaInfo: CGImageAlphaInfo = useAlphaChannel ? .premultipliedLast : .noneSkipLast
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: alphaInfo.rawValue
        ) else {
            throw PipelineError.renderFailed
        }
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = interpolationQuality
        context.draw(
            image,
            in: drawRect ?? CGRect(x: 0, y: 0, width: width, height: height)
        )
        guard let rendered = context.makeImage() else {
            throw PipelineError.renderFailed
        }
        return rendered
    }

    /// Encode pixels and metadata together. The caller supplies a temporary output URL.
    static func write(
        image: CGImage,
        opened: OpenedFile,
        to url: URL,
        rawWidth: Int,
        rawHeight: Int,
        preserveMetadata: Bool = true
    ) throws {
        if opened.saveFormat == "WEBP" {
            // WebP stores alpha separately, so transparency does not require lossless RGB encoding.
            try WebPImageWriter.write(
                image: image,
                to: url,
                metadataExifTiff: opened.webpExifChunk,
                lossless: false,
                compressionMethod: 0,
                inputIsCanonicalRGBA8: true,
                atomicWrite: false
            )
            return
        }

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            opened.uti,
            1,
            nil
        ) else {
            throw PipelineError.saveFailed
        }

        var properties = preserveMetadata ? opened.properties : [:]
        properties[kCGImagePropertyPixelWidth] = rawWidth
        properties[kCGImagePropertyPixelHeight] = rawHeight
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = rawWidth
            exif[kCGImagePropertyExifPixelYDimension] = rawHeight
            properties[kCGImagePropertyExifDictionary] = exif
        }
        let destinationProperties = ImageReencodeMetadata.destinationEncodeProperties(
            saveFormat: opened.saveFormat,
            base: properties
        )
        CGImageDestinationAddImage(destination, image, destinationProperties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PipelineError.saveFailed
        }
    }
}
