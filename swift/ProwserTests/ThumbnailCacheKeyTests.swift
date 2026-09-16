import XCTest
@testable import Prowser

final class ThumbnailCacheKeyTests: XCTestCase {
    func testDiskFilenameFormat() {
        XCTAssertEqual(ThumbnailCacheKey.diskFilename(cacheKey: "abc123", size: 256), "abc123_256.jpg")
    }

    func testBuildKeyMaterialIncludesExifFlag() {
        let a = ThumbnailCacheKey.buildKeyMaterial(path: "/x/y.jpg", mtime: 100, ignoreExifRotation: false)
        let b = ThumbnailCacheKey.buildKeyMaterial(path: "/x/y.jpg", mtime: 100, ignoreExifRotation: true)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.contains("_exif0"))
        XCTAssertTrue(b.contains("_exif1"))
    }

    func testMd5HexStable() {
        let hex = ThumbnailCacheKey.md5Hex("test-material")
        XCTAssertEqual(hex.count, 32)
        XCTAssertEqual(hex, ThumbnailCacheKey.md5Hex("test-material"))
    }
}
