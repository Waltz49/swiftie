import XCTest
@testable import Prowser

final class GenerationTimingKeyBuilderTests: XCTestCase {
    func testRealisticVisionTimingKey() {
        let dataDir = FileManager.default.temporaryDirectory
        let result = GenerationTimingKeyBuilder.build(
            pluginID: "realistic_vision_v4_sd15",
            values: [
                "width": 512,
                "height": 512,
                "steps": 25,
                "hf_model_id": "SG161222/Realistic_Vision_V4.0_noVAE",
            ],
            dataDirectory: dataDir
        )
        XCTAssertEqual(result.key?.modelID, "SG161222/Realistic_Vision_V4.0_noVAE")
        XCTAssertEqual(result.key?.steps, 25)
        XCTAssertEqual(result.key?.width, 512)
        XCTAssertEqual(result.key?.height, 512)
    }
}
