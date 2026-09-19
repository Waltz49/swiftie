import XCTest
@testable import Prowser

final class ResNetFeatureExtractorTests: XCTestCase {
    func testResNet101FeatureVectorLooksSane() throws {
        let path = "/Volumes/MiscFS/judges/image-judges-0005.webp"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("MiscFS not mounted")
        }
        let profile = ProfilePaths(profilePath: "/tmp/nerb")
        let extractor = ResNetFeatureExtractor(resnetModel: "resnet101", profile: profile)
        let vec = try extractor.extractFeature(path: path)
        XCTAssertEqual(vec.count, 2048)
        var sumSq: Float = 0
        var nonzero = 0
        for x in vec {
            sumSq += x * x
            if abs(x) > 1e-6 { nonzero += 1 }
        }
        let norm = sqrt(sumSq)
        print("[ResNetFeatureExtractorTests] norm=\(norm) nonzero=\(nonzero) first4=\(Array(vec.prefix(4)))")
        XCTAssertGreaterThan(norm, 8, "L2 norm should match PyTorch/CoreML (~17), not garbage (~40961)")
        XCTAssertLessThan(norm, 40)
        XCTAssertGreaterThan(nonzero, 200)
    }
}
