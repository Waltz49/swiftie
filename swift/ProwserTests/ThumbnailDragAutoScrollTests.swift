import XCTest
@testable import Prowser

final class ThumbnailDragAutoScrollTests: XCTestCase {
    func testSpeedTableMatchesPythonInterpolation() {
        XCTAssertEqual(ThumbnailDragAutoScroll.percentPerSecond(distanceFromEdge: 100), 25.6, accuracy: 0.001)
        XCTAssertEqual(ThumbnailDragAutoScroll.percentPerSecond(distanceFromEdge: 95), 38.4, accuracy: 0.001)
        XCTAssertEqual(ThumbnailDragAutoScroll.percentPerSecond(distanceFromEdge: 90), 51.2, accuracy: 0.001)
        XCTAssertEqual(ThumbnailDragAutoScroll.percentPerSecond(distanceFromEdge: 50), 153.6, accuracy: 0.001)
        XCTAssertEqual(ThumbnailDragAutoScroll.percentPerSecond(distanceFromEdge: 15), 243.2, accuracy: 0.001)
        XCTAssertEqual(ThumbnailDragAutoScroll.percentPerSecond(distanceFromEdge: 10), 256, accuracy: 0.001)
        XCTAssertEqual(ThumbnailDragAutoScroll.percentPerSecond(distanceFromEdge: 0), 256, accuracy: 0.001)
        XCTAssertEqual(ThumbnailDragAutoScroll.percentPerSecond(distanceFromEdge: 150), 25.6, accuracy: 0.001)
    }

    func testScrollStepUsesHundredPointBandAndViewportPercent() {
        let height: CGFloat = 800
        let width: CGFloat = 400
        XCTAssertEqual(
            ThumbnailDragAutoScroll.scrollStep(
                xInViewport: 10, yInViewport: 150, viewportWidth: width, viewportHeight: height
            ),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ThumbnailDragAutoScroll.scrollStep(
                xInViewport: 10, yInViewport: 100, viewportWidth: width, viewportHeight: height
            ),
            0,
            accuracy: 0.001
        )
        let nearTop = ThumbnailDragAutoScroll.scrollStep(
            xInViewport: 10, yInViewport: 95, viewportWidth: width, viewportHeight: height
        )
        XCTAssertEqual(nearTop, -4.9152, accuracy: 0.001)
        let nearBottom = ThumbnailDragAutoScroll.scrollStep(
            xInViewport: 10, yInViewport: 750, viewportWidth: width, viewportHeight: height
        )
        XCTAssertEqual(nearBottom, 19.6608, accuracy: 0.001)
        let atEdge = ThumbnailDragAutoScroll.scrollStep(
            xInViewport: 10, yInViewport: 0, viewportWidth: width, viewportHeight: height
        )
        XCTAssertEqual(atEdge, -32.768, accuracy: 0.001)
        XCTAssertEqual(
            ThumbnailDragAutoScroll.scrollStep(
                xInViewport: -1, yInViewport: 0, viewportWidth: width, viewportHeight: height
            ),
            0,
            accuracy: 0.001
        )
    }
}
