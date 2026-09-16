import XCTest
@testable import Prowser

final class DirectoryScannerTests: XCTestCase {
    func testMatchesGlobStar() {
        XCTAssertTrue(DirectoryScanner.matchesGlob("photo.jpg", pattern: "*"))
        XCTAssertTrue(DirectoryScanner.matchesGlob("photo.jpg", pattern: ""))
    }

    func testMatchesGlobPrefixSuffix() {
        XCTAssertTrue(DirectoryScanner.matchesGlob("vacation_001.jpg", pattern: "*.jpg"))
        XCTAssertFalse(DirectoryScanner.matchesGlob("vacation_001.png", pattern: "*.jpg"))
        XCTAssertTrue(DirectoryScanner.matchesGlob("IMG_1234.raw", pattern: "IMG_*"))
        XCTAssertTrue(DirectoryScanner.matchesGlob("middlematch", pattern: "*match*"))
    }

    func testMatchesGlobExact() {
        XCTAssertTrue(DirectoryScanner.matchesGlob("only.png", pattern: "only.png"))
        XCTAssertFalse(DirectoryScanner.matchesGlob("only.jpg", pattern: "only.png"))
    }
}
