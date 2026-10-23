import XCTest
@testable import Prowser

final class ImageGenPromptLayoutTests: XCTestCase {
    func testClampedVisibleLinesRespectsMinAndMax() {
        XCTAssertEqual(
            ImageGenPromptLayout.clampedVisibleLines(contentLines: 1, minLines: 4, maxLines: 22),
            4
        )
        XCTAssertEqual(
            ImageGenPromptLayout.clampedVisibleLines(contentLines: 10, minLines: 4, maxLines: 22),
            10
        )
        XCTAssertEqual(
            ImageGenPromptLayout.clampedVisibleLines(contentLines: 30, minLines: 4, maxLines: 22),
            22
        )
    }

    func testHeightForLinesIncreasesWithLineCount() {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let h4 = ImageGenPromptLayout.heightForLines(4, font: font)
        let h8 = ImageGenPromptLayout.heightForLines(8, font: font)
        XCTAssertGreaterThan(h8, h4)
    }
}
