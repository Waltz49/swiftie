import XCTest
@testable import Prowser

final class ThumbnailOptimalGridSizeTests: XCTestCase {
    func testPartialPageUsesLargerThanMinimumSize() {
        ThumbnailGridLayoutService.invalidateOptimalSizeCache()
        let size = ThumbnailGridLayoutService.calculateOptimalThumbnailSize(
            numImages: 5,
            viewportWidth: 1000,
            viewportHeight: 800,
            scrollbarWidth: 15,
            overlayHeight: 0
        )
        XCTAssertGreaterThan(size, ThumbnailGridLayoutService.minThumbnailSize)
    }

    func testSingleColumnLayoutDoesNotResetEnlargedSize() {
        let result = ThumbnailGridLayoutService.calculateGridForImages(
            numImages: 8,
            availableWidth: 420,
            availableHeight: 900,
            overlayHeight: 0
        )
        XCTAssertGreaterThan(result.optimalSize, ThumbnailGridLayoutService.minThumbnailSize)
    }
}
