import XCTest
@testable import Prowser

final class QueueJobStatusBuilderTests: XCTestCase {
    func testContinuousSeriesCopiesLineShowsContinuous() {
        let result = QueueJobStatusBuilder.build(
            pluginID: "realistic_vision_v4_sd15",
            function: "create",
            values: ["prompt": "test", "width": 512, "height": 512, "steps": 20],
            copiesTotal: JobStepQueue.seriesContinuousCopies
        )
        let fp = result.statusView.fingerprint()
        XCTAssertTrue(fp.contains("lv:Copies:"))
        XCTAssertTrue(fp.contains("Continuous"))
        XCTAssertFalse(fp.contains("51 images"))
    }

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
        XCTAssertTrue(fp.contains("prompt:Prompt:"))
        XCTAssertTrue(fp.contains(":test"))
    }

    func testQueuedFluxAIJobShowsGenerationParamsNotStageRow() {
        let result = QueueJobStatusBuilder.build(
            pluginID: "flux_schnell_mflux",
            function: "create",
            values: [
                "prompt": "bicycle ride",
                "width": 512,
                "height": 512,
                "steps": 8,
                JobStepQueue.fluxPromptAIJobKey: ["user_prompt": "refine me"],
            ],
            copiesTotal: 1,
            withAI: true
        )
        let fp = result.statusView.fingerprint()
        XCTAssertTrue(fp.contains("+AI"))
        XCTAssertTrue(fp.contains("lv:Model:"))
        XCTAssertFalse(fp.contains("lv:Stage:"))
    }

    func testActiveAIStageShowsStageRow() {
        let result = QueueJobStatusBuilder.build(
            pluginID: "flux_schnell_mflux",
            function: "create",
            values: [
                "prompt": "bicycle ride",
                JobStepQueue.fluxPromptAIJobKey: ["user_prompt": "refine me"],
            ],
            copiesTotal: 1,
            running: true,
            aiStageActive: true,
            step: 1,
            stepTotal: 8
        )
        let fp = result.statusView.fingerprint()
        XCTAssertTrue(fp.contains("lv:Stage:"))
        XCTAssertTrue(fp.contains("AI prompt refinement"))
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
