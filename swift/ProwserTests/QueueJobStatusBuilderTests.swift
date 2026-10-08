import XCTest
@testable import Prowser

final class QueueJobStatusBuilderTests: XCTestCase {
    func testRealisticVisionShowsModelSizeSteps() {
        let result = QueueJobStatusBuilder.build(
            pluginID: "realistic_vision_v4_sd15",
            function: "create",
            values: [
                "prompt": "test",
                "width": 512,
                "height": 512,
                "steps": 20,
            ],
            copiesTotal: 1
        )
        let fp = result.statusView.fingerprint()
        XCTAssertTrue(fp.contains("lv:Model:"))
        XCTAssertTrue(fp.contains("Realistic"))
        XCTAssertTrue(fp.contains("512 x 512"))
        XCTAssertTrue(fp.contains("20"))
        XCTAssertTrue(fp.contains("prompt:test"))
    }

    func testUnavailablePlugin() {
        let result = QueueJobStatusBuilder.build(
            pluginID: "unknown_plugin",
            function: "create",
            values: ["prompt": "x"],
            copiesTotal: 2,
            pluginUnavailable: true
        )
        XCTAssertTrue(result.statusView.rows.contains(where: {
            if case .unavailable(let heading, _, _) = $0 {
                return heading.contains("unknown_plugin")
            }
            return false
        }))
    }
}
