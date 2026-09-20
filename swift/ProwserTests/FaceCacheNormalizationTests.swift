import XCTest
@testable import Prowser

final class FaceCacheNormalizationTests: XCTestCase {
    func testPathHashPrefixLength() {
        let hash = FaceCacheNormalization.pathHash("/tmp/example.jpg")
        XCTAssertEqual(hash.count, 24)
    }

    func testNormalizeUsesStandardizedPath() {
        let norm = FaceCacheNormalization.normalizePathForFaceCache("/tmp/../tmp/foo.jpg")
        XCTAssertTrue(norm.hasSuffix("foo.jpg"))
    }
}
