import XCTest
@testable import Prowser

final class StepwiseProgressNameTests: XCTestCase {
    func testParsesStandardMfluxName() {
        let parsed = StepwiseProgressName.parse("seed_123_step2of8.png")
        XCTAssertEqual(parsed?.step, 2)
        XCTAssertEqual(parsed?.total, 8)
    }

    func testIgnoresCompositeAndNonMfluxNames() {
        XCTAssertNil(StepwiseProgressName.parse("seed_1_step2of8_composite.png"))
        XCTAssertNil(StepwiseProgressName.parse("seed_99_step_3_of_4.png"))
        XCTAssertNil(StepwiseProgressName.parse("readme.txt"))
        XCTAssertNil(StepwiseProgressName.parse("seed_1_step2of8.jpg"))
    }
}
