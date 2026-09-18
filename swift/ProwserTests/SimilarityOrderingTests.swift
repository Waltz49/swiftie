import XCTest
@testable import Prowser

final class SimilarityOrderingTests: XCTestCase {
    func testCosineOrder() {
        let ref = [Float(1), 0, 0]
        let features: [String: [Float]] = [
            "/a": [1, 0, 0],
            "/b": [0.9, 0.1, 0],
            "/c": [0, 1, 0],
        ]
        let ordered = SimilarityOrdering.orderBySimilarity(
            paths: ["/c", "/b", "/a"],
            features: features,
            referencePaths: ["/a"],
            metric: .cosine
        )
        XCTAssertEqual(ordered.first, "/a")
        XCTAssertEqual(ordered[1], "/b")
    }

    func testClipThreshold() {
        let text = [Float(1), 0]
        let features: [String: [Float]] = [
            "/hi": [0.95, 0.05],
            "/low": [0.1, 0.9],
        ]
        let ranked = SimilarityOrdering.clipTextRanked(
            paths: ["/hi", "/low"],
            features: features,
            textFeature: text,
            minimumSimilarity: 0.5
        )
        XCTAssertEqual(ranked, ["/hi"])
    }
}
