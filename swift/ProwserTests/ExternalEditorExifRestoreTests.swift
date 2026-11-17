import CoreGraphics
import Foundation
@testable import Prowser
import XCTest

final class ExternalEditorExifRestoreTests: XCTestCase {
    func testWebPUserCommentRawPayloadRestoreAfterPixelmatorStyleStrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prowser-external-editor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let path = directory.appendingPathComponent("edit-me.webp").path
        let image = try makeRGBAImage(width: 64, height: 64)
        try WebPImageWriter.write(image: image, to: URL(fileURLWithPath: path), metadataExifTiff: nil,
                                 compressionMethod: 0, inputIsCanonicalRGBA8: true)

        let comment = "Prompt:\nA studio portrait of a cat\nModel: test"
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let mtime = attrs[.modificationDate] as? Date
        try ExifUserCommentRestore.restore(
            path: path,
            userCommentPayload: ExifService.encodeUserCommentData(comment),
            mtime: mtime,
            atime: nil
        )

        guard let originalPayload = ExifService.userCommentRawPayload(path: path) else {
            XCTFail("expected UserComment payload before strip")
            return
        }
        XCTAssertEqual(ExifService.decodeUserComment(originalPayload), comment)

        var webpData = try Data(contentsOf: URL(fileURLWithPath: path))
        webpData = try WebPImageWriter.dataWithoutExifChunk(webpData: webpData)
        try webpData.write(to: URL(fileURLWithPath: path), options: .atomic)
        XCTAssertNil(ExifService.userCommentRawPayload(path: path))

        try ExifUserCommentRestore.restore(
            path: path,
            userCommentPayload: originalPayload,
            mtime: mtime,
            atime: nil
        )
        XCTAssertEqual(ExifService.userCommentRawPayload(path: path), originalPayload)
        XCTAssertEqual(ExifService.userComment(path: path), comment)
    }

    private func makeRGBAImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
        let image = context.makeImage() else {
            throw NSError(domain: "ExternalEditorExifRestoreTests", code: 1)
        }
        return image
    }
}