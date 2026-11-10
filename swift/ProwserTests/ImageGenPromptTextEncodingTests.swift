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

    func testJobCardHoverOriginalPrefersRowFullPrompt() {
        let values: [String: Any] = ["prompt": "from values"]
        XCTAssertEqual(
            JobCardHoverFullPrompt.original(rowFullPrompt: "from row", jobValues: values),
            "from row"
        )
    }

    func testJobCardHoverOriginalFallsBackToEffectiveTooltip() {
        let values: [String: Any] = ["prompt": "queued user text"]
        XCTAssertEqual(JobCardHoverFullPrompt.original(rowFullPrompt: "", jobValues: values), "queued user text")
    }

    func testJobCardHoverActiveWorkerPromptMatchesProgressStripOrder() {
        XCTAssertEqual(
            JobCardHoverFullPrompt.activeWorkerPrompt(
                workerPrompt: "worker",
                refinedPrompt: "refined",
                valuesPrompt: "values",
                displayFullPrompt: "display"
            ),
            "worker"
        )
        XCTAssertEqual(
            JobCardHoverFullPrompt.activeWorkerPrompt(
                workerPrompt: "",
                refinedPrompt: "refined",
                valuesPrompt: "values",
                displayFullPrompt: "display"
            ),
            "refined"
        )
        XCTAssertEqual(
            JobCardHoverFullPrompt.activeWorkerPrompt(
                workerPrompt: "",
                refinedPrompt: "",
                valuesPrompt: "values",
                displayFullPrompt: "display"
            ),
            "values"
        )
    }

    @MainActor
    func testJobCardHoverPromptModeParsing() {
        let config = ProwserTestSupport.ephemeralAppConfig()
        XCTAssertEqual(JobCardHoverPromptMode.from(config: config), .original)
        config.setValue(JobCardHoverPromptMode.modifiedValue, forKey: JobCardHoverPromptMode.settingsKey)
        XCTAssertEqual(JobCardHoverPromptMode.from(config: config), .modified)
    }

    func testEffectiveJobTooltipShowsLoremPlaceholderNotExpandedBlocks() {
        let values: [String: Any] = [
            "prompt": "prefix {{old lorem block}} suffix",
        ]
        let tooltip = FluxPromptJobValues.effectiveJobPromptForTooltip(values)
        XCTAssertTrue(tooltip.contains("[L]"))
        XCTAssertFalse(tooltip.contains("{{old lorem"))
    }

    func testValuesForDialogSaveKeepsRawPromptNotExited() {
        let submit: [String: Any] = [
            "prompt": "arm binder {{lorem ipsum}}",
            "negative_prompt": "blur",
            "seed": 7,
        ]
        let saved = ImageGenDialogPromptPersistence.valuesForDialogSave(
            submitValues: submit,
            dialogPrompt: "arm binder [L]",
            negativePrompt: "blur"
        )
        XCTAssertEqual(saved["prompt"] as? String, "arm binder [L]")
        XCTAssertEqual(saved["negative_prompt"] as? String, "blur")
        XCTAssertEqual(saved["seed"] as? Int, 7)
    }

    func testFormattedExifPromptWithDoubleBracesIsNotMfluxJSON() {
        let body = "arm binder {{lorem ipsum}}"
        let comment = ImageGenExifCommentFormatting.formatImageExifPrompt(
            modelName: "Test Model",
            promptText: body,
            seed: 1
        )
        XCTAssertNil(ImageGenExifCommentFormatting.parseMfluxMetadataJSON(comment))
        let data = ExifCommentData(text: comment)
        XCTAssertEqual(data.prompt, body)
        XCTAssertEqual(ImageGenExifCommentFormatting.extractedPromptText(from: comment), body)
        XCTAssertTrue(ExifCommentData.hasImageModelSection(comment))
    }

    func testRepairUTF8BytesMisinterpretedAsLatin1() {
        let once = String(data: Data([0x50, 0x61, 0x6e, 0x65, 0x6c, 0xc3, 0xb0, 0xc2, 0x9f, 0xc2, 0x9a, 0xc2, 0xab]), encoding: .utf8)!
        XCTAssertEqual(ImageGenPromptTextEncoding.repairUTF8BytesMisinterpretedAsLatin1(once), "Panel🚫")
        XCTAssertEqual(ImageGenPromptTextEncoding.repairUTF8BytesMisinterpretedAsLatin1("Panel🚫"), "Panel🚫")
    }

    func testPrimeEditorPromptRepairsStoredMojibake() {
        let once = String(data: Data([0x50, 0x61, 0x6e, 0x65, 0x6c, 0xc3, 0xb0, 0xc2, 0x9f, 0xc2, 0x9a, 0xc2, 0xab]), encoding: .utf8)!
        let primed = ImageGenDialogPromptPersistence.primeEditorPrompt(
            jobValues: ["prompt": once],
            fullPrompt: ""
        )
        XCTAssertEqual(primed, "Panel🚫")
    }

    func testSentenceCasePreservesCJKContent() {
        let input = "  日本語の説明  "
        let out = ImageGenPromptSentenceCase.normalized(input)
        XCTAssertTrue(out.contains("日本語"))
        XCTAssertTrue(ImageGenPromptTextEncoding.preservesUTF8RoundTrip(out))
    }
}
