import XCTest
@testable import Prowser

final class ImageGenPromptSentenceCaseTests: XCTestCase {
    func testNormalizedLowercasesAndAddsPeriod() {
        let out = ImageGenPromptSentenceCase.normalized("  HELLO   world  ")
        XCTAssertEqual(out, "Hello world.")
    }

    func testCapitalizesAfterSentencePunctuation() {
        let out = ImageGenPromptSentenceCase.normalized("hello. world")
        XCTAssertEqual(out, "Hello. World.")
    }

    func testCapitalizesAfterSpacedHyphen() {
        let out = ImageGenPromptSentenceCase.normalized("foo - bar")
        XCTAssertEqual(out, "Foo - Bar.")
    }

    func testPerLineMode() {
        let input = "line one\nline two"
        let out = ImageGenPromptSentenceCase.normalized(input, perLine: true)
        XCTAssertEqual(out, "Line one.\nLine two.")
    }

    func testAfterPromptExitDoesNotLowercase() {
        let out = ImageGenPromptSentenceCase.afterPromptExit("HELLO world")
        XCTAssertEqual(out, "HELLO world")
    }

    func testFlushPromptValues() {
        var values: [String: Any] = ["prompt": "hello", "negative_prompt": "bad stuff"]
        ImageGenPromptSentenceCase.flushPromptValues(&values)
        XCTAssertEqual(values["prompt"] as? String, "Hello.")
        XCTAssertEqual(values["negative_prompt"] as? String, "Bad stuff.")
    }
}
