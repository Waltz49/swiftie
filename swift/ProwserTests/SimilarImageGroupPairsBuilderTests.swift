import XCTest
@testable import Prowser

final class SimilarImageGroupPairsBuilderTests: XCTestCase {
    func testMseIdenticalArraysZero() {
        let a = [Float](repeating: 0.5, count: 12)
        XCTAssertEqual(SimilarImageGroupPairsBuilder.mse(a, a), 0, accuracy: 1e-6)
    }

    func testClusterUsesMinimumPathAsGroupKey() {
        let rgb = [Float](repeating: 0.4, count: 9)
        let loaded = [
            (path: "/tmp/z/photo.jpg", rgb: rgb),
            (path: "/tmp/a/photo.jpg", rgb: rgb),
        ]
        guard let groups = SimilarImageGroupPairsBuilder.clusterLoaded(loaded: loaded) else {
            XCTFail("expected groups")
            return
        }
        XCTAssertEqual(groups.count, 1)
        let sorted = groups[0].sorted()
        XCTAssertEqual(sorted, ["/tmp/a/photo.jpg", "/tmp/z/photo.jpg"])
        let groupKey = sorted.min()
        XCTAssertEqual(groupKey, "/tmp/a/photo.jpg")
    }

    func testMseThresholdSeparatesDifferentPixels() {
        let a = [Float](repeating: 0.0, count: 300)
        var b = [Float](repeating: 0.0, count: 300)
        b[0] = 1.0
        let mse = SimilarImageGroupPairsBuilder.mse(a, b)
        XCTAssertGreaterThan(mse, SimilarImageGroupPairsBuilder.mseThreshold)
    }

    func testCompareBucketKeySameAspectDifferentResolution() {
        let a = SimilarImageGroupPairsBuilder.compareBucketKey(orientedWidth: 4000, orientedHeight: 3000)
        let b = SimilarImageGroupPairsBuilder.compareBucketKey(orientedWidth: 800, orientedHeight: 600)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "128x96")
    }

    func testCompareBucketKeyDifferentAspect() {
        let landscape = SimilarImageGroupPairsBuilder.compareBucketKey(orientedWidth: 1920, orientedHeight: 1080)
        let portrait = SimilarImageGroupPairsBuilder.compareBucketKey(orientedWidth: 1080, orientedHeight: 1920)
        XCTAssertNotEqual(landscape, portrait)
    }

    func testDigestUnionGroupsIdenticalArrays() {
        let rgb = (0 ..< 30).map { Float($0) / 30 }
        let loaded = [
            (path: "/one.jpg", rgb: rgb),
            (path: "/two.jpg", rgb: rgb),
            (path: "/three.jpg", rgb: [Float](repeating: 1, count: 30)),
        ]
        guard let groups = SimilarImageGroupPairsBuilder.clusterLoaded(loaded: loaded) else {
            XCTFail("expected groups")
            return
        }
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0]), Set(["/one.jpg", "/two.jpg"]))
    }
}
