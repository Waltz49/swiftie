import XCTest
@testable import Prowser

final class ThumbnailLayoutExtensionsTests: XCTestCase {
    func testIncrementalExtensionsByStemMatchesFullScan() {
        let paths = [
            "/a/photo.jpg",
            "/a/photo.png",
            "/a/other.webp",
        ]
        let full = ThumbnailLayout.basenamesWithMultipleExtensions(in: paths)
        var map = ThumbnailLayout.rebuildExtensionsByStem(from: paths)
        XCTAssertEqual(full, ThumbnailLayout.basenamesNeedingExtensions(from: map))

        ThumbnailLayout.mutateExtensionsByStem(for: "/a/photo.gif", add: true, into: &map)
        let withGif = ThumbnailLayout.basenamesNeedingExtensions(from: map)
        XCTAssertTrue(withGif.contains("photo"))

        ThumbnailLayout.mutateExtensionsByStem(for: "/a/photo.png", add: false, into: &map)
        ThumbnailLayout.mutateExtensionsByStem(for: "/a/photo.jpg", add: false, into: &map)
        ThumbnailLayout.mutateExtensionsByStem(for: "/a/photo.gif", add: false, into: &map)
        XCTAssertFalse(ThumbnailLayout.basenamesNeedingExtensions(from: map).contains("photo"))
    }

    func testReorderOnlyLeavesBasenamesUnchangedWhenMultisetSame() {
        let paths = ["/a/x.jpg", "/a/y.png", "/a/x.webp"]
        let map = ThumbnailLayout.rebuildExtensionsByStem(from: paths)
        let before = ThumbnailLayout.basenamesNeedingExtensions(from: map)
        XCTAssertTrue(before.contains("x"))
        // Reorder does not mutate map.
        let reordered = ["/a/y.png", "/a/x.jpg", "/a/x.webp"]
        let rescan = ThumbnailLayout.basenamesWithMultipleExtensions(in: reordered)
        XCTAssertEqual(before, rescan)
    }
}
