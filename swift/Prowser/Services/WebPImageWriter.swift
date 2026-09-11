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
        lossless: Bool = false
    ) throws {
        let encoder = WebPEncoder()
        var config = WebPEncoderConfig.preset(.picture, quality: 95)
        config.method = 6
        if lossless {
            config.lossless = 1
        }

        let encoded: Data
        if cgImageHasAlpha(image) {
            encoded = try encoder.encode(RGBA: image, config: config)
        } else {
            encoded = try encoder.encode(RGB: image, config: config)
        }

        var output = encoded
        if let sourcePathForMetadata,
           let exifChunk = extractExifChunk(from: sourcePathForMetadata) {
            output = try muxExifChunk(into: encoded, exif: exifChunk)
        }

        try output.write(to: url, options: .atomic)
    }

    private static func cgImageHasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            return true
        }
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
