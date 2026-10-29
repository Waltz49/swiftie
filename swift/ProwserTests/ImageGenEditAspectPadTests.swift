import CoreGraphics
import ImageIO
import XCTest
@testable import Prowser

final class ImageGenEditAspectPadTests: XCTestCase {
    func testFitDimensionsShrinksWithoutUpscale() {
        let (w, h) = ImageGenEditAspectPad.fitDimensions(
            width: 2000,
            height: 1000,
            refWidth: 1000,
            refHeight: 1000,
            allowUpscale: false
        )
        XCTAssertEqual(w, 1000)
        XCTAssertEqual(h, 500)
    }

    func testFitDimensionsUpscalesWhenAllowed() {
        let (w, h) = ImageGenEditAspectPad.fitDimensions(
            width: 512,
            height: 512,
            refWidth: 1024,
            refHeight: 1024,
            allowUpscale: true
        )
        XCTAssertEqual(w, 1024)
        XCTAssertEqual(h, 1024)
    }

    func testAspectPaddingFitsLaterImagesToFirstSize() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("edit-aspect-pad-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let first = dir.appendingPathComponent("first.png").path
        let second = dir.appendingPathComponent("second.png").path
        XCTAssertTrue(createSolidPNG(at: first, width: 128, height: 64))
        XCTAssertTrue(createSolidPNG(at: second, width: 64, height: 128))

        let (paths, temps) = ImageGenEditAspectPad.generatorPathsWithAspectPadding(
            sourcePaths: [first, second],
            tempRoot: dir
        )
        XCTAssertEqual(paths.count, 2)
        XCTAssertEqual(paths[0], first)
        XCTAssertNotEqual(paths[1], second)
        XCTAssertEqual(temps.count, 1)
        XCTAssertEqual(paths[1], temps[0])
        XCTAssertEqual(ImageRecognitionImageLoader.orientedPixelSize(path: paths[1])?.width, 128)
        XCTAssertEqual(ImageRecognitionImageLoader.orientedPixelSize(path: paths[1])?.height, 64)
    }

    func testCustomSizeThenAspectPaddingPreservesAllSources() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("edit-custom-multi-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let first = dir.appendingPathComponent("a.png").path
        let second = dir.appendingPathComponent("b.png").path
        XCTAssertTrue(createSolidPNG(at: first, width: 80, height: 40))
        XCTAssertTrue(createSolidPNG(at: second, width: 40, height: 80))

        let expanded = ImageGenEditAspectPad.generatorPathsWithScreenSizeExpansion(
            sourcePaths: [first, second],
            targetWidth: 160,
            targetHeight: 160,
            tempRoot: dir
        )
        XCTAssertEqual(expanded.generatorPaths.count, 2)
        XCTAssertNotEqual(expanded.generatorPaths[0], first)
        XCTAssertEqual(expanded.generatorPaths[1], second)

        let padded = ImageGenEditAspectPad.generatorPathsWithAspectPadding(
            sourcePaths: expanded.generatorPaths,
            tempRoot: dir
        )
        XCTAssertEqual(padded.generatorPaths.count, 2)
        XCTAssertEqual(padded.generatorPaths[0], expanded.generatorPaths[0])
        XCTAssertNotEqual(padded.generatorPaths[1], second)
        XCTAssertEqual(ImageRecognitionImageLoader.orientedPixelSize(path: padded.generatorPaths[0])?.width, 160)
        XCTAssertEqual(ImageRecognitionImageLoader.orientedPixelSize(path: padded.generatorPaths[1])?.width, 160)
        XCTAssertEqual(ImageRecognitionImageLoader.orientedPixelSize(path: padded.generatorPaths[1])?.height, 160)
    }

    private func createSolidPNG(at path: String, width: Int, height: Int) -> Bool {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            return false
        }
        guard let destination = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
