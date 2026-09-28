import XCTest
@testable import Prowser

@MainActor
final class ThumbnailFilenameOverlayCacheTests: XCTestCase {
    func testOverlayCacheAvoidsRepeatCompute() {
        let cache = ThumbnailFilenameOverlayCache()
        cache.clear()
        let path = "/tmp/sample/long_filename_for_cache_test.jpg"
        _ = ThumbnailFilenameOverlayService.overlay(
            for: path,
            cellWidth: 140,
            showFilename: true,
            showImageSize: false,
            showExtensions: false,
            basenamesNeedingExtensions: [],
            displayStyle: .basename,
            wrapMode: .cellWidth,
            cache: cache
        )
        let firstCount = cache.computeCount
        _ = ThumbnailFilenameOverlayService.overlay(
            for: path,
            cellWidth: 140,
            showFilename: true,
            showImageSize: false,
            showExtensions: false,
            basenamesNeedingExtensions: [],
            displayStyle: .basename,
            wrapMode: .cellWidth,
            cache: cache
        )
        XCTAssertEqual(cache.computeCount, firstCount)
    }
}
