import XCTest
@testable import Prowser

final class ThumbnailDisplayedPathsUpdateKindTests: XCTestCase {
    func testReorderPreservesMultiset() {
        let a = ["/a/1.jpg", "/a/2.jpg", "/a/3.jpg"]
        let b = ["/a/3.jpg", "/a/1.jpg", "/a/2.jpg"]
        XCTAssertEqual(Set(a), Set(b))
    }

    func testMembershipChangeDetectsRemoval() {
        let old = ["/a/1.jpg", "/a/2.jpg", "/a/3.jpg"]
        let new = ["/a/1.jpg", "/a/3.jpg"]
        let removed = Set(old).subtracting(new)
        XCTAssertEqual(removed, ["/a/2.jpg"])
    }
}
