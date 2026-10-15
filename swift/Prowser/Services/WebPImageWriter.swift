import CoreGraphics
import Foundation
import WebP
import libwebp

/// WebP encoding via libwebp. macOS ImageIO can decode WebP but cannot create WebP destinations.
enum WebPImageWriter {
    enum WriteError: LocalizedError {
        case encodeFailed
        case muxFailed

        var errorDescription: String? {
            switch self {
            case .encodeFailed: return "Failed to encode WebP"
            case .muxFailed: return "Failed to write WebP metadata"
            }
        }
    }

    static func write(
        image: CGImage,
        to url: URL,
        sourcePathForMetadata: String? = nil,
        metadataExifTiff: Data? = nil,
        lossless: Bool = false
    ) throws {
        let encoder = WebPEncoder()
        var config = WebPEncoderConfig.preset(.picture, quality: 95)
        config.method = 6
        if lossless {
            config.lossless = 1
        }

        // ImageIO/CGImage pixel layout varies (often BGRA); encoding via data provider bytes corrupts output.
        let raster = canonicalRGBA8Image(from: image)
        let encoded = try encoder.encode(RGBA: raster, config: config)

        var output = encoded
        let exifChunk = metadataExifTiff
            ?? sourcePathForMetadata.flatMap { extractExifChunk(from: $0) }
        if let exifChunk {
            output = try muxExifChunk(into: encoded, exif: exifChunk)
        }

        try output.write(to: url, options: .atomic)
    }

    /// Draw into RGBA8 / premultipliedLast so libwebp `WebPPictureImportRGBA` matches memory layout.
    private static func canonicalRGBA8Image(from image: CGImage) -> CGImage {
        let width = image.width
        let height = image.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return image
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private static func extractExifChunk(from path: String) -> Data? {
        guard let fileData = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return fileData.withUnsafeBytes { rawBuffer -> Data? in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            var input = WebPData(bytes: base, size: fileData.count)
            guard let mux = WebPMuxCreate(&input, 1) else { return nil }
            defer { WebPMuxDelete(mux) }

            var chunk = WebPData()
            let status = "EXIF".withCString { fourcc in
                WebPMuxGetChunk(mux, fourcc, &chunk)
            }
            guard status == WEBP_MUX_OK, chunk.size > 0, let chunkBytes = chunk.bytes else { return nil }
            return Data(bytes: chunkBytes, count: chunk.size)
        }
    }

    /// Replace or add the WebP `EXIF` chunk without re-encoding image data (port of piexif.insert for WebP).
    static func dataWithReplacedExifChunk(webpData: Data, exifTiff: Data) throws -> Data {
        try muxExifChunk(into: webpData, exif: exifTiff)
    }

    private static func muxExifChunk(into webpData: Data, exif: Data) throws -> Data {
        var assembled = Data()
        let muxError: WebPMuxError = webpData.withUnsafeBytes { webpBuffer in
            exif.withUnsafeBytes { exifBuffer in
                guard let webpBase = webpBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let exifBase = exifBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return WEBP_MUX_INVALID_ARGUMENT
                }
                var webpInput = WebPData(bytes: webpBase, size: webpData.count)
                guard let mux = WebPMuxCreate(&webpInput, 1) else {
                    return WEBP_MUX_BAD_DATA
                }
                defer { WebPMuxDelete(mux) }

                var exifData = WebPData(bytes: exifBase, size: exif.count)
                guard "EXIF".withCString({ WebPMuxSetChunk(mux, $0, &exifData, 1) }) == WEBP_MUX_OK else {
                    return WEBP_MUX_BAD_DATA
                }

                var output = WebPData()
                guard WebPMuxAssemble(mux, &output) == WEBP_MUX_OK, let outBytes = output.bytes else {
                    return WEBP_MUX_BAD_DATA
                }
                assembled = Data(bytes: outBytes, count: output.size)
                WebPDataClear(&output)
                return WEBP_MUX_OK
            }
        }
        guard muxError == WEBP_MUX_OK else { throw WriteError.muxFailed }
        return assembled
    }
}
