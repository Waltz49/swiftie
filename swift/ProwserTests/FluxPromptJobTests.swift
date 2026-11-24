import XCTest
@testable import Prowser

@MainActor
final class FluxPromptJobTests: XCTestCase {
    func testSyncJobCheckboxClearsWhenJobHasNoAIMeta() {
        let context = ImageGenFluxPromptSubmitContext()
        context.jobCheckbox = true
        FluxPromptJob.syncJobCheckboxFromValues(values: ["prompt": "test"], context: context)
        XCTAssertFalse(context.jobCheckbox)
    }

    func testPrepareRunValuesStripsAIWhenSectionCollapsedAndJobAIOff() {
        let context = ImageGenFluxPromptSubmitContext()
        context.lmStudioMounted = true
        context.sectionExpanded = false
        context.jobCheckbox = false
        context.promptText = "a prompt"
        context.taskKind = "create"
        var values: [String: Any] = [
            "prompt": "a prompt",
            JobStepQueue.fluxPromptAIJobKey: ["user_prompt": "old"],
        ]
        let config = ProwserTestSupport.ephemeralAppConfig()
        let ok = FluxPromptJob.applyFluxPromptJobToPrepareRunValues(
            context: context,
            config: config,
            values: &values,
            force: false
        )
        XCTAssertTrue(ok)
        XCTAssertFalse(JobStepQueue.hasFluxPromptAIJob(values))
    }

    func testPrepareRunValuesAttachesAIWhenJobCheckboxOnSectionCollapsed() {
        let context = ImageGenFluxPromptSubmitContext()
        context.lmStudioMounted = true
        context.sectionExpanded = false
        context.jobCheckbox = true
        context.promptText = "a prompt"
        context.taskKind = "create"
        var values: [String: Any] = ["prompt": "a prompt"]
        let config = ProwserTestSupport.ephemeralAppConfig()
        let ok = FluxPromptJob.applyFluxPromptJobToPrepareRunValues(
            context: context,
            config: config,
            values: &values,
            force: false
        )
        XCTAssertTrue(ok)
        XCTAssertTrue(JobStepQueue.hasFluxPromptAIJob(values))
    }

    func testSyncNextCopyPreservesSystemPrompt() {
        var values: [String: Any] = [
            JobStepQueue.fluxPromptAIJobKey: [
                "system_prompt": "Per-job system",
                "user_prompt": "first",
                "pass_image": false,
            ],
            "prompt": "second copy",
        ]
        FluxPromptJobValues.syncFluxPromptAIUserPromptForNextCopy(values: &values)
        guard let meta = values[JobStepQueue.fluxPromptAIJobKey] as? [String: Any] else {
            XCTFail("missing meta")
            return
        }
        XCTAssertEqual(meta["system_prompt"] as? String, "Per-job system")
        XCTAssertEqual(meta["user_prompt"] as? String, "second copy")
        XCTAssertEqual(meta["pass_image"] as? Bool, false)
    }

    func testPrepareRunValuesFailsWhenJobCheckboxOnButAttachFails() {
        let context = ImageGenFluxPromptSubmitContext()
        context.lmStudioMounted = true
        context.sectionExpanded = false
        context.jobCheckbox = true
        context.passImage = true
        context.promptText = ""
        context.taskKind = "create"
        var values: [String: Any] = [
            "prompt": "",
            JobStepQueue.fluxPromptAIJobKey: ["user_prompt": "prior"],
        ]
        let config = ProwserTestSupport.ephemeralAppConfig()
        let ok = FluxPromptJob.applyFluxPromptJobToPrepareRunValues(
            context: context,
            config: config,
            values: &values,
            force: false
        )
        XCTAssertFalse(ok)
        XCTAssertFalse(JobStepQueue.hasFluxPromptAIJob(values))
    }

    func testSyncJobCheckboxOnWhenJobHasAIMeta() {
        let context = ImageGenFluxPromptSubmitContext()
        context.jobCheckbox = false
        let values: [String: Any] = [
            JobStepQueue.fluxPromptAIJobKey: [
                "user_prompt": "hello",
                "system_prompt": "sys",
                "pass_image": false,
            ],
        ]
        FluxPromptJob.syncJobCheckboxFromValues(values: values, context: context)
        XCTAssertTrue(context.jobCheckbox)
    }

    func testPrepareRunValuesAttachesAIWhenSectionExpandedAndCheckboxOn() {
        let context = ImageGenFluxPromptSubmitContext()
        context.lmStudioMounted = true
        context.sectionExpanded = true
        context.jobCheckbox = true
        context.promptText = "a prompt"
        context.taskKind = "create"
        var values: [String: Any] = ["prompt": "a prompt"]
        let config = ProwserTestSupport.ephemeralAppConfig()
        let ok = FluxPromptJob.applyFluxPromptJobToPrepareRunValues(
            context: context,
            config: config,
            values: &values,
            force: false
        )
        XCTAssertTrue(ok)
        XCTAssertTrue(JobStepQueue.hasFluxPromptAIJob(values))
        let meta = values[JobStepQueue.fluxPromptAIJobKey] as? [String: Any]
        XCTAssertEqual(meta?["pass_image"] as? Bool, false)
        XCTAssertFalse((meta?["system_prompt"] as? String ?? "").isEmpty)
    }
}