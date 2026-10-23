import XCTest
@testable import Prowser

final class AIRefineProgressTests: XCTestCase {
    func testStepFromCharsMapsToBudget() {
        XCTAssertEqual(AIRefineProgress.stepFromChars(charsReceived: 0), 0)
        XCTAssertEqual(AIRefineProgress.stepFromChars(charsReceived: 800), 99)
        XCTAssertEqual(AIRefineProgress.stepFromChars(charsReceived: 2000), 99)
    }

    func testDisplayStepQuantizesToRefreshBoundaries() {
        XCTAssertEqual(AIRefineProgress.displayStep(step: 0), 0)
        XCTAssertEqual(AIRefineProgress.displayStep(step: 19), 0)
        XCTAssertEqual(AIRefineProgress.displayStep(step: 20), 20)
        XCTAssertEqual(AIRefineProgress.displayStep(step: 39), 20)
        XCTAssertEqual(AIRefineProgress.displayStep(step: 40), 40)
    }
}
