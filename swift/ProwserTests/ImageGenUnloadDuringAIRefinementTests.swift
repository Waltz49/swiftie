import XCTest
@testable import Prowser

final class ImageGenUnloadDuringAIRefinementTests: XCTestCase {
    @MainActor
    func testDefaultSettingsLeavesUnloadDuringAIRefinementOff() {
        XCTAssertEqual(
            AppConfig.defaultSettings()["imagegen_unload_image_models_during_ai_refinement"] as? Bool,
            false
        )
    }
}