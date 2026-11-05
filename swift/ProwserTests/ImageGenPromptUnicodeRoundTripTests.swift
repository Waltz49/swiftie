import ImageIO
import XCTest
@testable import Prowser

/// End-to-end Unicode preservation: dialog values → queue JSON → EXIF UserComment → import / job edit.
final class ImageGenPromptUnicodeRoundTripTests: XCTestCase {
    private static let samplePrompts = [
        "日本語プロンプト 🎨",
        "café — naïve \"quotes\" and 'apostrophe'",
        "👨‍👩‍👧‍👦 family scene",
        "Mixed: Hello 世界 🌍",
    ]

    func testFormattedExifCommentExtractsUnicodePrompt() {
        for prompt in Self.samplePrompts {
            let comment = ImageGenExifCommentFormatting.formatImageExifPrompt(
                modelName: "Test Model",
                promptText: prompt,
                seed: 42,
                steps: 9
            )
            let extracted = ImageGenExifCommentFormatting.extractedPromptText(from: comment)
            XCTAssertEqual(extracted, prompt.trimmingCharacters(in: .whitespacesAndNewlines), prompt)
            let initial = ExifService.initialPromptFromUserComment(comment)
            XCTAssertEqual(initial, extracted)
        }
    }

    func testDisplayFormatAndExtractPreservesUnicode() {
        for prompt in Self.samplePrompts {
            let formatted = ImageGenExifCommentFormatting.formatImageExifPrompt(
                modelName: "FLUX.1 Schnell",
                promptText: prompt,
                seed: 1
            )
            let displayed = ImageGenExifCommentFormatting.formatUserCommentTextForDisplay(formatted)
            let extracted = ImageGenExifCommentFormatting.extractedPromptText(from: displayed)
            XCTAssertEqual(extracted, prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func testMfluxJSONInExifExtractsUnicodePrompt() {
        for prompt in Self.samplePrompts {
            let meta: [String: Any] = [
                "prompt": prompt,
                "seed": 99,
                "steps": 4,
                "model": "black-forest-labs/FLUX.1-schnell",
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: meta),
                  let json = String(data: data, encoding: .utf8) else {
                XCTFail("json encode failed")
                continue
            }
            let extracted = ImageGenExifCommentFormatting.extractedPromptText(from: json)
            XCTAssertEqual(extracted, prompt)
        }
    }

    func testJobQueueDocumentRoundTripPreservesPrompt() throws {
        for prompt in Self.samplePrompts {
            var values: [String: Any] = [
                "prompt": prompt,
                "negative_prompt": "neg \(prompt)",
                "seed": 7,
                "steps": 8,
            ]
            ImageGenPromptSentenceCase.flushPromptValues(&values)
            let job = ImageGenQueuedJob(
                pluginID: "flux_schnell_play",
                function: "create",
                values: values,
                fullPrompt: values["prompt"] as? String ?? prompt
            )
            let data = try JSONSerialization.data(withJSONObject: job.document, options: [])
            let loaded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let restored = ImageGenQueuedJob(document: loaded ?? [:])
            let primed = ImageGenDialogPromptPersistence.primeEditorPrompt(
                jobValues: restored.values,
                fullPrompt: restored.fullPrompt
            )
            XCTAssertEqual(restored.values["prompt"] as? String, values["prompt"] as? String)
            XCTAssertEqual(restored.values["negative_prompt"] as? String, values["negative_prompt"] as? String)
            XCTAssertEqual(primed, values["prompt"] as? String)
            XCTAssertTrue(ImageGenPromptTextEncoding.preservesUTF8RoundTrip(primed))
        }
    }

    func testGenerationExifCommentRoundTripExtract() {
        let prompt = Self.samplePrompts[0]
        let values: [String: Any] = [
            "prompt": prompt,
            "seed": 123,
            "steps": 9,
            "guidance_scale": 0,
            "hf_model_id": LoRAHFModelIDs.zImageTurboMflux4Bit,
        ]
        let comment = ImageGenGenerationExifService.formatGenerationExifComment(
            pluginID: "z_image_turbo_mflux_4bit",
            values: values,
            workerResult: ["seed": 123],
            elapsedSeconds: 12,
            lora: nil
        )
        let injected = ImageGenGenerationExifService.injectReferences(
            baseComment: comment,
            pluginID: "z_image_turbo_mflux_4bit",
            values: values,
            outputPath: "/tmp/out/imagegen-0001.png",
            fallbackSourcePaths: [],
            tempRoot: "/tmp"
        )
        let extracted = ImageGenExifCommentFormatting.extractedPromptText(from: injected)
        XCTAssertEqual(extracted, prompt)
    }

    func testEncodeUserCommentPayloadPreservesUnicode() {
        for prompt in Self.samplePrompts {
            let payload = ExifService.encodeUserCommentData(prompt)
            XCTAssertGreaterThan(payload.count, 8)
            let decoded = ExifService.decodeUserComment(payload)
            XCTAssertEqual(decoded, prompt)
        }
    }

    func testPiexifSegmentBuildFromFormattedComment() {
        let prompt = Self.samplePrompts[0]
        let comment = ImageGenExifCommentFormatting.formatImageExifPrompt(
            modelName: "Test Model",
            promptText: prompt,
            seed: 1
        )
        let payload = ExifService.encodeUserCommentData(comment)
        _ = ExifPiexifSegmentBuilder.build(userCommentPayload: payload)
    }

    func testInsertIntoPNGProducesValidFile() throws {
        let png = Self.minimalPNGData()
        let payload = ExifService.encodeUserCommentData("hello")
        let segment = ExifPiexifSegmentBuilder.build(userCommentPayload: payload)
        _ = try ExifSegmentInserter.insertIntoPNG(exifSegment: segment, png: png)
    }

    func testPiexifSegmentBuildWithUnicodePayload() {
        let payload = ExifService.encodeUserCommentData(Self.samplePrompts[0])
        _ = ExifPiexifSegmentBuilder.build(userCommentPayload: payload)
    }

    func testInsertIntoPNGWithUnicodePayload() throws {
        let payload = ExifService.encodeUserCommentData(Self.samplePrompts[0])
        let segment = ExifPiexifSegmentBuilder.build(userCommentPayload: payload)
        _ = try ExifSegmentInserter.insertIntoPNG(exifSegment: segment, png: Self.minimalPNGData())
    }

    func testWritePNGWithExifChunkDoesNotTrap() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("unicode-write-\(UUID().uuidString).png").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let payload = ExifService.encodeUserCommentData("日本語")
        let segment = ExifPiexifSegmentBuilder.build(userCommentPayload: payload)
        let out = try ExifSegmentInserter.insertIntoPNG(exifSegment: segment, png: Self.minimalPNGData())
        try out.write(to: URL(fileURLWithPath: path), options: .atomic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testEmbeddedReaderReadsASCIIPayload() throws {
        let text = "hello"
        let payload = ExifService.encodeUserCommentData(text)
        let segment = ExifPiexifSegmentBuilder.build(userCommentPayload: payload)
        let out = try ExifSegmentInserter.insertIntoPNG(exifSegment: segment, png: Self.minimalPNGData())
        let read = ExifEmbeddedTIFFReader.userComment(fromImageData: out)
        XCTAssertEqual(read, text)
    }

    func testEmbeddedReaderReadsASCIIPayloadFromDisk() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("ascii-read-\(UUID().uuidString).png").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let text = "hello"
        let payload = ExifService.encodeUserCommentData(text)
        let segment = ExifPiexifSegmentBuilder.build(userCommentPayload: payload)
        let out = try ExifSegmentInserter.insertIntoPNG(exifSegment: segment, png: Self.minimalPNGData())
        try out.write(to: URL(fileURLWithPath: path), options: .atomic)
        _ = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(ExifEmbeddedTIFFReader.userComment(fromFile: path), text)
    }

    func testEmbeddedReaderReadsSimpleUnicodePayload() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("unicode-read3-\(UUID().uuidString).png").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let text = "日本語"
        let payload = ExifService.encodeUserCommentData(text)
        let segment = ExifPiexifSegmentBuilder.build(userCommentPayload: payload)
        let out = try ExifSegmentInserter.insertIntoPNG(exifSegment: segment, png: Self.minimalPNGData())
        try out.write(to: URL(fileURLWithPath: path), options: .atomic)

        XCTAssertEqual(ExifEmbeddedTIFFReader.userComment(fromFile: path), text)
    }

    func testEmbeddedReaderReadsUnicodePayload() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("unicode-read2-\(UUID().uuidString).png").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let text = Self.samplePrompts[0]
        let payload = ExifService.encodeUserCommentData(text)
        let segment = ExifPiexifSegmentBuilder.build(userCommentPayload: payload)
        let out = try ExifSegmentInserter.insertIntoPNG(exifSegment: segment, png: Self.minimalPNGData())
        try out.write(to: URL(fileURLWithPath: path), options: .atomic)

        XCTAssertEqual(ExifEmbeddedTIFFReader.userComment(fromFile: path), text)
    }

    func testEmbeddedReaderReadsInsertedUnicodeComment() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("unicode-read-\(UUID().uuidString).png").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let prompt = Self.samplePrompts[0]
        let comment = ImageGenExifCommentFormatting.formatImageExifPrompt(
            modelName: "Test Model",
            promptText: prompt,
            seed: 1
        )
        let payload = ExifService.encodeUserCommentData(comment)
        let segment = ExifPiexifSegmentBuilder.build(userCommentPayload: payload)
        let out = try ExifSegmentInserter.insertIntoPNG(exifSegment: segment, png: Self.minimalPNGData())
        try out.write(to: URL(fileURLWithPath: path), options: .atomic)

        let read = ExifEmbeddedTIFFReader.userComment(fromFile: path)
        XCTAssertEqual(
            ImageGenExifCommentFormatting.extractedPromptText(from: read ?? ""),
            prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func testNativeExifSegmentInsertPreservesUnicodeOnPNG() throws {
        let fm = FileManager.default
        let path = fm.temporaryDirectory
            .appendingPathComponent("unicode-native-exif-\(UUID().uuidString).png").path
        try Self.minimalPNGData().write(to: URL(fileURLWithPath: path), options: .atomic)
        defer { try? fm.removeItem(atPath: path) }

        let prompt = Self.samplePrompts[0]
        let comment = ImageGenExifCommentFormatting.formatImageExifPrompt(
            modelName: "Test Model",
            promptText: prompt,
            seed: 1
        )
        let payload = ExifService.encodeUserCommentData(comment)
        let segment = ExifPiexifSegmentBuilder.build(userCommentPayload: payload)
        let pngData = try Data(contentsOf: URL(fileURLWithPath: path))
        let out = try ExifSegmentInserter.insertIntoPNG(exifSegment: segment, png: pngData)
        try out.write(to: URL(fileURLWithPath: path), options: .atomic)

        let readEmbedded = ExifEmbeddedTIFFReader.userComment(fromFile: path)
        XCTAssertNotNil(readEmbedded)
        let extracted = ImageGenExifCommentFormatting.extractedPromptText(from: readEmbedded ?? "")
        XCTAssertEqual(extracted, prompt.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @MainActor
    func testWriteReadExifFilePreservesUnicodePrompt() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("unicode-exif-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }

        for prompt in Self.samplePrompts {
            let path = (dir as NSString).appendingPathComponent("img-\(UUID().uuidString).png")
            try writeMinimalPNG(at: path)

            let comment = ImageGenExifCommentFormatting.formatImageExifPrompt(
                modelName: "Test Model",
                promptText: prompt,
                seed: 1
            )
            try await ExifService.writeUserComment(path: path, text: comment)

            guard let read = ExifService.userComment(path: path) else {
                XCTFail("missing user comment")
                continue
            }
            let extracted = ImageGenExifCommentFormatting.extractedPromptText(from: read)
            XCTAssertEqual(extracted, prompt.trimmingCharacters(in: .whitespacesAndNewlines), prompt)

            let importPrompt = ExifService.importPromptText(from: path)
            XCTAssertEqual(importPrompt, extracted)
        }
    }

    @MainActor
    func testWriteReadRawMfluxJSONExifPreservesUnicodePrompt() async throws {
        let prompt = "场景 🌸 \"detail\""
        let meta: [String: Any] = [
            "prompt": prompt,
            "seed": 1,
            "steps": 2,
            "model": "black-forest-labs/FLUX.1-schnell",
        ]
        let json = try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: meta), encoding: .utf8))

        let fm = FileManager.default
        let path = fm.temporaryDirectory
            .appendingPathComponent("unicode-mflux-\(UUID().uuidString).png").path
        try writeMinimalPNG(at: path)
        defer { try? fm.removeItem(atPath: path) }

        try await ExifService.writeUserComment(path: path, text: json)
        let read = ExifService.userComment(path: path) ?? ""
        XCTAssertEqual(ImageGenExifCommentFormatting.extractedPromptText(from: read), prompt)
    }

    private static func minimalPNGData() -> Data {
        // 1×1 RGBA PNG (no ImageIO / main-thread dependency).
        Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
        """)!
    }

    private func writeMinimalPNG(at path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let image = context.makeImage() else {
            throw NSError(domain: "ImageGenPromptUnicodeRoundTripTests", code: 1)
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "ImageGenPromptUnicodeRoundTripTests", code: 2)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "ImageGenPromptUnicodeRoundTripTests", code: 3)
        }
    }
}
