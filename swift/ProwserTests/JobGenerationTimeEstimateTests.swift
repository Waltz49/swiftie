import XCTest
@testable import Prowser

final class JobGenerationTimeEstimateTests: XCTestCase {
    func testSetupUsesHistoricalMinusElapsed() {
        let remaining = JobGenerationTimeEstimate.remainingSeconds(
            elapsed: 30,
            completedStep: 0,
            totalSteps: 20,
            historicalAvgTotalSeconds: 120,
            firstStepDuration: nil,
            interStepDurations: []
        )
        XCTAssertEqual(remaining, 90)
    }

    func testFirstStepInProgressStillUsesHistorical() {
        let remaining = JobGenerationTimeEstimate.remainingSeconds(
            elapsed: 30,
            completedStep: 1,
            totalSteps: 20,
            historicalAvgTotalSeconds: 120,
            firstStepDuration: nil,
            interStepDurations: []
        )
        XCTAssertEqual(remaining, 90)
    }

    func testEarlyDiffusionUsesFirstStepDuration() {
        let remaining = JobGenerationTimeEstimate.remainingSeconds(
            elapsed: 50,
            completedStep: 2,
            totalSteps: 20,
            historicalAvgTotalSeconds: 120,
            firstStepDuration: 4,
            interStepDurations: [],
            partialStepElapsed: 0
        )
        XCTAssertEqual(remaining, 72)
    }

    func testDiffusionEstimateCountsDownWithinStep() {
        let remaining = JobGenerationTimeEstimate.remainingSeconds(
            elapsed: 50,
            completedStep: 2,
            totalSteps: 20,
            historicalAvgTotalSeconds: 120,
            firstStepDuration: 4,
            interStepDurations: [],
            partialStepElapsed: 2
        )
        XCTAssertEqual(remaining, 70)
    }

    func testRollingDiffusionUsesMeanInterStepDurations() {
        let durations = [4.0, 5.0, 4.0]
        let mean = durations.reduce(0, +) / Double(durations.count)
        let remaining = JobGenerationTimeEstimate.remainingSeconds(
            elapsed: 80,
            completedStep: 4,
            totalSteps: 20,
            historicalAvgTotalSeconds: 120,
            firstStepDuration: 4,
            interStepDurations: durations,
            partialStepElapsed: 0
        )
        XCTAssertEqual(remaining, mean * 16)
    }

    func testCompletedReturnsZero() {
        let remaining = JobGenerationTimeEstimate.remainingSeconds(
            elapsed: 100,
            completedStep: 20,
            totalSteps: 20,
            historicalAvgTotalSeconds: 120,
            firstStepDuration: 4,
            interStepDurations: [4, 4]
        )
        XCTAssertEqual(remaining, 0)
    }

    func testNoHistoricalBeforeDiffusionReturnsNil() {
        let remaining = JobGenerationTimeEstimate.remainingSeconds(
            elapsed: 10,
            completedStep: 0,
            totalSteps: 20,
            historicalAvgTotalSeconds: nil,
            firstStepDuration: nil,
            interStepDurations: []
        )
        XCTAssertNil(remaining)
    }

    func testDiffusionWithoutMeasuredStepReturnsNil() {
        let remaining = JobGenerationTimeEstimate.remainingSeconds(
            elapsed: 50,
            completedStep: 2,
            totalSteps: 20,
            historicalAvgTotalSeconds: nil,
            firstStepDuration: nil,
            interStepDurations: []
        )
        XCTAssertNil(remaining)
    }

    func testStepTimingStateRecordsFirstAndInterStepDurations() {
        var state = JobGenerationStepTimingState()
        let t0 = Date()
        state.recordStepAdvance(from: 0, to: 1, now: t0)
        state.recordStepAdvance(from: 1, to: 2, now: t0.addingTimeInterval(4))
        XCTAssertEqual(state.firstStepDuration, 4)
        XCTAssertTrue(state.interStepDurations.isEmpty)

        state.recordStepAdvance(from: 2, to: 3, now: t0.addingTimeInterval(9))
        XCTAssertEqual(state.interStepDurations, [5])
    }
}
