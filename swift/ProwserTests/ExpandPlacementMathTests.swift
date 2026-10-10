import XCTest
@testable import Prowser

final class ExpandPlacementMathTests: XCTestCase {
    func testCenteredFitIsVerticallyCentered() {
        let fit = ExpandPlacementMath.centeredFit(canvasW: 1024, canvasH: 1024, sourceAspect: 2.0)
        XCTAssertEqual(fit.x, (1024 - fit.w) / 2)
        XCTAssertEqual(fit.y, (1024 - fit.h) / 2)
    }

    func testRelativePlacementRoundTrip() {
        let rel = ExpandPlacementMath.storeRelative(
            placementX: 100,
            placementY: 50,
            placementW: 400,
            placementH: 300,
            canvasW: 800,
            canvasH: 600
        )
        let applied = ExpandPlacementMath.applyRelative(rel, canvasW: 800, canvasH: 600)
        XCTAssertEqual(applied.x, 100)
        XCTAssertEqual(applied.y, 50)
        XCTAssertEqual(applied.w, 400)
        XCTAssertEqual(applied.h, 300)
    }
}
