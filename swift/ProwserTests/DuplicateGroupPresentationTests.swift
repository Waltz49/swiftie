import XCTest
@testable import Prowser

final class DuplicateGroupPresentationTests: XCTestCase {
    func testAutoSelectKeepsLexicographicallySmallestInHashGroup() {
        let pairs: [(hash: String, path: String)] = [
            ("aa", "/tmp/a/photo.jpg"),
            ("aa", "/tmp/a/photo_copy.jpg"),
            ("aa", "/tmp/b/photo.jpg"),
            ("aa", "/tmp/b/photo_dup.jpg"),
        ]
        let selected = DuplicateGroupPresentation.perDirectoryAutoSelectPaths(groupPathPairs: pairs)
        XCTAssertEqual(
            selected,
            Set([
                "/tmp/a/photo_copy.jpg",
                "/tmp/b/photo.jpg",
                "/tmp/b/photo_dup.jpg",
            ])
        )
    }

    func testAutoSelectWhenOneCopyPerSubdirectory() {
        let pairs: [(hash: String, path: String)] = [
            ("bb", "/scan/alpha/x.jpg"),
            ("bb", "/scan/beta/y.jpg"),
        ]
        let selected = DuplicateGroupPresentation.perDirectoryAutoSelectPaths(groupPathPairs: pairs)
        XCTAssertEqual(selected, Set(["/scan/beta/y.jpg"]))
    }
}
