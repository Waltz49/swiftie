import XCTest
@testable import Prowser

final class ImageGenPromptTextEncodingTests: XCTestCase {
    func testUTF8RoundTripPreservesEmojiAndCJK() {
        let samples = [
            "Hello 🌍",
            "日本語プロンプト",
            "café — naïve",
            "👨‍👩‍👧‍👦 family",
        ]
        for sample in samples {
            XCTAssertTrue(ImageGenPromptTextEncoding.preservesUTF8RoundTrip(sample))
            guard let data = ImageGenPromptTextEncoding.utf8Data(from: sample) else {
                XCTFail("utf8 encode failed: \(sample)")
                continue
            }
            XCTAssertEqual(ImageGenPromptTextEncoding.stringFromUTF8(data), sample)
        }
    }

    func testSuffixAfterPrefixUsesUnicodeScalarsNotBytes() {
        let prefix = "Hi 🌍"
        let full = "Hi 🌍 — more"
        XCTAssertEqual(ImageGenPromptTextEncoding.suffix(afterPrefix: prefix, in: full), " — more")
    }

    func testUTF16LengthMatchesNSStringForEmoji() {
        let text = "a🌍b"
        XCTAssertEqual(ImageGenPromptTextEncoding.utf16Length(of: text), (text as NSString).length)
        XCTAssertEqual(ImageGenPromptTextEncoding.utf16Length(of: text), 4)
    }

    func testJobQueueJSONRoundTripPreservesQuotesInPrompt() throws {
        let prompt = #"She said "hello" and 'bye'"#
        let values: [String: Any] = ["prompt": prompt, "seed": 42]
        let job = ImageGenQueuedJob(
            pluginID: "flux_schnell_play",
            function: "create",
            values: values,
            fullPrompt: prompt
        )
        let doc = job.document
        let data = try JSONSerialization.data(withJSONObject: doc, options: [])
        let loaded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let restored = ImageGenQueuedJob(document: loaded ?? [:])
        XCTAssertEqual(restored.values["prompt"] as? String, prompt)
        XCTAssertEqual(
            ImageGenDialogPromptPersistence.primeEditorPrompt(
                jobValues: restored.values,
                fullPrompt: restored.fullPrompt
            ),
            prompt
        )
    }

    func testRestoreLoremPlaceholdersForDialog() {
        let input = "Start {{lorem ipsum \"quote\"}} end"
        let out = AIPromptExitService.restoreLoremPlaceholdersForDialog(input)
        XCTAssertEqual(out, "Start [L] end")
        XCTAssertEqual(AIPromptExitService.restoreLoremPlaceholdersForDialog(#"say "hi""#), #"say "hi""#)
    }

    func testSentenceCasePreservesCJKContent() {
        let input = "  日本語の説明  "
        let out = ImageGenPromptSentenceCase.normalized(input)
        XCTAssertTrue(out.contains("日本語"))
        XCTAssertTrue(ImageGenPromptTextEncoding.preservesUTF8RoundTrip(out))
    }
}
