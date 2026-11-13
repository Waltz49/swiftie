import XCTest
@testable import Prowser

@MainActor
final class QueueJobStatusRefresherTests: XCTestCase {
    override func setUp() {
        super.setUp()
        QueueJobStatusRefresher.resetTestingCounters()
        QueueJobStatusRefresher.clearAllFingerprints()
    }

    func testSkipRebuildWhenFingerprintMatches() {
        let jobID = "job-a"
        let values: [String: Any] = ["prompt": "hello", "steps": 4]
        let fp = QueueJobStatusRefresher.inputsFingerprint(
            pluginID: "mflux_schnell",
            function: "create",
            values: values,
            copiesTotal: 1,
            pluginUnavailable: false,
            storedFullPrompt: "hello",
            loraLabel: nil,
            hasFluxAI: false
        )
        QueueJobStatusRefresher.recordFingerprint(jobID: jobID, fingerprint: fp)
        let view = QueueJobStatusView(rows: [.labelValue(label: "Prompt:", value: "hello")], running: false)
        XCTAssertTrue(
            QueueJobStatusRefresher.shouldSkipStatusRebuild(jobID: jobID, fingerprint: fp, statusView: view)
        )
        XCTAssertEqual(QueueJobStatusRefresher.buildSkippedBecauseFingerprintCountForTesting, 1)
    }

    func testRebuildWhenValuesChange() {
        let jobID = "job-b"
        let values: [String: Any] = ["prompt": "a"]
        let fp1 = QueueJobStatusRefresher.inputsFingerprint(
            pluginID: "mflux_schnell",
            function: "create",
            values: values,
            copiesTotal: 1,
            pluginUnavailable: false,
            storedFullPrompt: "a",
            loraLabel: nil,
            hasFluxAI: false
        )
        QueueJobStatusRefresher.recordFingerprint(jobID: jobID, fingerprint: fp1)
        let view = QueueJobStatusView(rows: [], running: false)
        let fp2 = QueueJobStatusRefresher.inputsFingerprint(
            pluginID: "mflux_schnell",
            function: "create",
            values: ["prompt": "b"],
            copiesTotal: 1,
            pluginUnavailable: false,
            storedFullPrompt: "b",
            loraLabel: nil,
            hasFluxAI: false
        )
        XCTAssertFalse(
            QueueJobStatusRefresher.shouldSkipStatusRebuild(jobID: jobID, fingerprint: fp2, statusView: view)
        )
    }
}
