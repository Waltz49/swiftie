import XCTest
@testable import Prowser

final class ThumbnailStandardGridLayoutTests: XCTestCase {
    func testLongBasenameWrapsToMultipleLines() {
        let paths = [
            "/tmp/folder/My_Very_Long_Vacation_Photo_Name_2024_edited_final_version.jpg",
        ]
        let layout = ThumbnailStandardGridLayout.compute(
            paths: paths,
            viewportWidth: 500,
            thumbnailSize: 150,
            showFilename: true,
            showImageSize: false,
            showExtensions: false,
            basenamesNeedingExtensions: []
        )
        let lines = layout.wrappedLines[0] ?? []
        XCTAssertGreaterThan(lines.count, 1)
        let joined = lines.joined()
        XCTAssertTrue(joined.contains("Vacation"))
        XCTAssertFalse(joined.contains("…"))
    }

    func testRowHeightUsesMaxOverlayInRow() {
        let short = "/tmp/a/short.jpg"
        let long = "/tmp/a/extremely_long_basename_for_thumbnail_wrapping_parity_check.jpg"
        let layout = ThumbnailStandardGridLayout.compute(
            paths: [short, long],
            viewportWidth: 900,
            thumbnailSize: 150,
            showFilename: true,
            showImageSize: false,
            showExtensions: false,
            basenamesNeedingExtensions: []
        )
        guard let frame0 = layout.itemFrames[0], let frame1 = layout.itemFrames[1] else {
            XCTFail("Missing item frames")
            return
        }
        XCTAssertEqual(frame0.minY, frame1.minY, accuracy: 0.5)
        XCTAssertGreaterThan((layout.overlayHeights[1] ?? 0), (layout.overlayHeights[0] ?? 0))
        XCTAssertGreaterThan(frame1.height, frame0.height)
    }
}
