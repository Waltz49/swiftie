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

    func testNormalizedTriggerWordNoTrailingPeriod() {
        let out = ImageGenPromptSentenceCase.normalizedTriggerWord("  HELLO   world  ")
        XCTAssertEqual(out, "Hello world")
        XCTAssertFalse(out.hasSuffix("."))
    }

    func testNormalizedTriggerWordSingleToken() {
        let out = ImageGenPromptSentenceCase.normalizedTriggerWord("MYTOKEN")
        XCTAssertEqual(out, "Mytoken")
        XCTAssertFalse(out.hasSuffix("."))
    }

    func testFlushLoraImportPayload() {
        var values: [String: Any] = [
            "trigger_word": "FOO bar",
            "comment": "some NOTE",
            "reference_prompt": "test IMAGE",
            "display_name": "Unchanged",
        ]
        ImageGenPromptSentenceCase.flushLoraImportPayload(&values)
        XCTAssertEqual(values["trigger_word"] as? String, "Foo bar")
        XCTAssertEqual(values["comment"] as? String, "Some note.")
        XCTAssertEqual(values["reference_prompt"] as? String, "Test image.")
        XCTAssertEqual(values["display_name"] as? String, "Unchanged")
    }

    func testFlushLoraImportPayloadSkipsWhenAlreadyNormalized() {
        var values: [String: Any] = ["trigger_word": "Mytoken", "comment": "Note."]
        ImageGenPromptSentenceCase.flushLoraImportPayload(&values)
        XCTAssertEqual(values["trigger_word"] as? String, "Mytoken")
        XCTAssertEqual(values["comment"] as? String, "Note.")
    }
}
