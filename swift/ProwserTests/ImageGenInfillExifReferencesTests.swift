import XCTest
@testable import Prowser

final class ImageGenInfillExifReferencesTests: XCTestCase {
    func testInfillReferenceEntriesPreferPixelmatorDocOverTempBase() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("infill-exif-\(UUID().uuidString)").path
        let libraryDir = fm.temporaryDirectory.appendingPathComponent("infill-library-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: libraryDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(atPath: tempRoot)
            try? fm.removeItem(atPath: libraryDir)
        }

        let libraryFile = (libraryDir as NSString).appendingPathComponent("photo.webp")
        XCTAssertTrue(fm.createFile(atPath: libraryFile, contents: Data([0x00])))
        let tempBase = (tempRoot as NSString).appendingPathComponent("imagegen-infill-base.png")
        XCTAssertTrue(fm.createFile(atPath: tempBase, contents: Data([0x00])))

        let outputDir = (tempRoot as NSString).appendingPathComponent("out")
        try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        let output = (outputDir as NSString).appendingPathComponent("imagegen-0001.png")
        XCTAssertTrue(fm.createFile(atPath: output, contents: Data([0x00])))

        let values: [String: Any] = [
            "pixelmator_doc_path": libraryFile,
            "pixelmator_base_path": tempBase,
            "source_image_path": tempBase,
        ]

        let entries = ImageGenGenerationExifService.referenceEntriesForOutput(
            pluginID: "flux_fill_infill",
            values: values,
            outputPath: output,
            fallbackSourcePaths: [tempBase],
            tempRoot: tempRoot
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].path, URL(fileURLWithPath: libraryFile).standardizedFileURL.path)
    }

    func testInjectReferencesIncludesLibraryReferenceLine() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("infill-exif-\(UUID().uuidString)").path
        let libraryDir = fm.temporaryDirectory.appendingPathComponent("infill-library-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: libraryDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(atPath: tempRoot)
            try? fm.removeItem(atPath: libraryDir)
        }

        let libraryFile = (libraryDir as NSString).appendingPathComponent("source.png")
        XCTAssertTrue(fm.createFile(atPath: libraryFile, contents: Data([0x00])))
        let tempBase = (tempRoot as NSString).appendingPathComponent("pixelmator-base.png")
        XCTAssertTrue(fm.createFile(atPath: tempBase, contents: Data([0x00])))

        let output = (tempRoot as NSString).appendingPathComponent("imagegen-0002.png")
        XCTAssertTrue(fm.createFile(atPath: output, contents: Data([0x00])))

        let values: [String: Any] = [
            "pixelmator_doc_path": libraryFile,
            "source_image_path": tempBase,
        ]
        let comment = ImageGenGenerationExifService.injectReferences(
            baseComment: "Prompt:\ntest",
            pluginID: "flux_fill_infill",
            values: values,
            outputPath: output,
            fallbackSourcePaths: [tempBase],
            tempRoot: tempRoot
        )
        XCTAssertTrue(comment.contains("References:"))
        XCTAssertTrue(comment.contains("source.png"))
    }
}
