import CoreGraphics
import Foundation
import ImageIO
@testable import Prowser
import XCTest

final class FastResizePipelineTests: XCTestCase {
    func testWebPResizeWritesRequestedSizeAndPreservesExifChunk() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prowser-fast-resize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.webp")
        let sourceImage = try makeImage(width: 1600, height: 1200)
        let exifChunk = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00])
        try WebPImageWriter.write(
            image: sourceImage,
            to: sourceURL,
            metadataExifTiff: exifChunk,
            compressionMethod: 0,
            inputIsCanonicalRGBA8: true
        )

        let result = await MainActor.run {
            ResizeImagesService.resizeFile(
                path: sourceURL.path,
                request: ResizeImagesService.ResizeRequest(
                    targetWidth: 800,
                    targetHeight: 600,
                    preserveAspect: false,
                    anchorIsWidth: true,
                    usePercentScale: false,
                    percentScale: 100,
                    resampleMethod: .lanczos,
                    deleteOriginal: false,
                    preserveDates: false,
                    ignoreExifRotation: false
                )
            )
        }

        XCTAssertTrue(result.success, result.error ?? "resize failed")
        let outputPath = try XCTUnwrap(result.outputPath)
        let outputURL = URL(fileURLWithPath: outputPath)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 800)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 600)

        let outputData = try Data(contentsOf: outputURL)
        XCTAssertEqual(WebPImageWriter.extractExifChunk(from: outputData), exifChunk)
    }

    func testWebPScreenSizeCopyUsesSameFastPipeline() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prowser-fast-screen-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.webp")
        try WebPImageWriter.write(
            image: try makeImage(width: 2400, height: 1600),
            to: sourceURL,
            compressionMethod: 0,
            inputIsCanonicalRGBA8: true
        )

        let outputPath = try ScreenSizeCopyService.createCopy(
            path: sourceURL.path,
            fitMethod: .contain,
            bordersOnCopy: true,
            preserveDates: false
        )

        let outputURL = URL(fileURLWithPath: outputPath)
        let output = try XCTUnwrap(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as? [CFString: Any]
        )
        let expected = ScreenSizeCopyService.physicalScreenSize()
        XCTAssertEqual(
            (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            Int(expected.width.rounded())
        )
        XCTAssertEqual(
            (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            Int(expected.height.rounded())
        )
    }

    func testResizePreservesExifOrientationWithoutExtraRasterPass() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prowser-oriented-resize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("oriented.jpg")
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(sourceURL as CFURL, "public.jpeg" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(
            destination,
            try makeImage(width: 120, height: 80),
            [kCGImagePropertyOrientation: 6] as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let result = await MainActor.run {
            ResizeImagesService.resizeFile(
                path: sourceURL.path,
                request: ResizeImagesService.ResizeRequest(
                    targetWidth: 40,
                    targetHeight: 60,
                    preserveAspect: false,
                    anchorIsWidth: true,
                    usePercentScale: false,
                    percentScale: 100,
                    resampleMethod: .lanczos,
                    deleteOriginal: false,
                    preserveDates: false,
                    ignoreExifRotation: false
                )
            )
        }

        XCTAssertTrue(result.success, result.error ?? "resize failed")
        let outputURL = URL(fileURLWithPath: try XCTUnwrap(result.outputPath))
        let output = try XCTUnwrap(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as? [CFString: Any]
        )
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 60)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 40)
        XCTAssertEqual((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 6)
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestError.imageCreationFailed
        }

        let tile = 64
        for y in stride(from: 0, to: height, by: tile) {
            for x in stride(from: 0, to: width, by: tile) {
                let red = CGFloat((x / tile) % 8) / 7
                let green = CGFloat((y / tile) % 8) / 7
                context.setFillColor(CGColor(red: red, green: green, blue: 0.5, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: tile, height: tile))
            }
        }
        guard let image = context.makeImage() else {
            throw TestError.imageCreationFailed
        }
        return image
    }

    private enum TestError: Error {
        case imageCreationFailed
    }
}
