import XCTest
@testable import Prowser

final class ImageGenInfillMathTests: XCTestCase {
    func testFitInfillPaintDimsUpscaleSmallImagesToModelMinimum() {
        let (w, h) = ImageGenInfillMath.fitInfillPaintDims(width: 256, height: 256, maxSide: 1024)
        XCTAssertEqual(w, ImageGenInfillMath.infillModelMinimumSide)
        XCTAssertEqual(h, ImageGenInfillMath.infillModelMinimumSide)
    }

    func testFitInfillPaintDimsScalesDownToMaxSide() {
        let (w, h) = ImageGenInfillMath.fitInfillPaintDims(width: 4000, height: 3000, maxSide: 1024)
        XCTAssertLessThanOrEqual(max(w, h), 1024)
        XCTAssertEqual(w % 16, 0)
        XCTAssertEqual(h % 16, 0)
        XCTAssertGreaterThanOrEqual(min(w, h), 256)
    }

    func testFitInfillPaintDimsPreservesAspectRoughly() {
        let (w, h) = ImageGenInfillMath.fitInfillPaintDims(width: 1920, height: 1080, maxSide: 1024)
        let ratio = Double(w) / Double(h)
        XCTAssertEqual(ratio, 1920.0 / 1080.0, accuracy: 0.05)
    }

    func testMissingInfillExportPaths() {
        let missing = InfillExportService.missingInfillExportPaths([:])
        XCTAssertEqual(missing.count, 2)
    }
}
