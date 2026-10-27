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

    func testLowercasesInteriorCapsOnNormalize() {
        let out = ImageGenPromptSentenceCase.normalized("a BOY named Sue")
        XCTAssertEqual(out, "A boy named sue.")
    }

    func testInsertsSpaceAfterPunctuation() {
        let out = ImageGenPromptSentenceCase.normalized("hello.world")
        XCTAssertEqual(out, "Hello. World.")
    }

    func testAfterPromptExitDoesNotLowercase() {
        let out = ImageGenPromptSentenceCase.afterPromptExit("HELLO world")
        XCTAssertEqual(out, "HELLO world")
    }

    func testFlushPromptValues() {
        var values: [String: Any] = ["prompt": "FOO bar", "negative_prompt": "bad STUFF"]
        ImageGenPromptSentenceCase.flushPromptValues(&values)
        XCTAssertEqual(values["prompt"] as? String, "Foo bar.")
        XCTAssertEqual(values["negative_prompt"] as? String, "Bad stuff.")
    }
}
