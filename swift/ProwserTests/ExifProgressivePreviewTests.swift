import XCTest
import ImageIO
@testable import Prowser

final class ExifProgressivePreviewTests: XCTestCase {
    @MainActor
    func testProgressiveExifOnPngBytesAtWebpPathMatchesFinalStyle() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("progressive-exif-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }

        let output = (dir as NSString).appendingPathComponent("imagegen-0001.webp")
        try writeMinimalPNG(at: output)
        XCTAssertFalse(ExifService.imageBytesMatchPathExtension(path: output))
        XCTAssertTrue(ExifService.canWriteExifToOnDiskRaster(path: output))

        let values: [String: Any] = [
            "prompt": "test prompt",
            "seed": 542_559_250,
            "steps": 9,
            "guidance_scale": 0,
            "hf_model_id": LoRAHFModelIDs.zImageTurboMflux4Bit,
        ]

        let wrote = try await ImageGenGenerationExifService.makeReadableUserCommentBeforeBrowse(
            pluginID: "z_image_turbo_mflux_4bit",
            outputPath: output,
            values: values,
            elapsedSeconds: 108,
            completedStep: 3,
            totalSteps: 9,
            fallbackSourcePaths: [],
            tempRoot: dir
        )
        XCTAssertTrue(wrote)

        let comment = ExifService.userComment(path: output) ?? ""
        XCTAssertTrue(comment.contains("Z-Image Turbo (4-bit)"))
        XCTAssertFalse(comment.contains("Guidance:"))
        XCTAssertFalse(comment.contains("Quantization:"))
        XCTAssertTrue(comment.contains("Seed: 542559250"))
    }

    @MainActor
    func testProgressiveExifFromMfluxJsonMatchesFinalStyleForKleinKV() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("progressive-exif-klein-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }

        let output = (dir as NSString).appendingPathComponent("imagegen-0002.webp")
        let mfluxJSON = """
        {"prompt":"scene","seed":1335284087,"steps":4,"quantize":4,"model":"black-forest-labs/FLUX.2-klein-9b-kv","lora_paths":["/tmp/a.safetensors"],"lora_scales":[1.0]}
        """
        try writeMinimalPNG(at: output)
        try await ExifService.writeUserComment(path: output, text: mfluxJSON)

        let values: [String: Any] = [
            "prompt": "scene",
            "seed": 1_335_284_087,
            "steps": 4,
            "mflux_quantize": 4,
            "hf_model_id": LoRAHFModelIDs.flux2Klein9BKV,
            "mflux_lora_stack": ["BallgagV2"],
            "mflux_lora_scales": [1.0],
        ]

        let wrote = try await ImageGenGenerationExifService.makeReadableUserCommentBeforeBrowse(
            pluginID: "flux_klein_9b_kv_create",
            outputPath: output,
            values: values,
            elapsedSeconds: 42,
            completedStep: 2,
            totalSteps: 4,
            fallbackSourcePaths: [],
            tempRoot: dir,
            lora: "F2K9B_BallgagV2_2020E10 [1]"
        )
        XCTAssertTrue(wrote)

        let comment = ExifService.userComment(path: output) ?? ""
        XCTAssertTrue(comment.hasPrefix("Image Model:"))
        XCTAssertTrue(comment.contains("FLUX 2 klein 9B KV"))
        XCTAssertTrue(comment.contains("Seed: 1335284087"))
        XCTAssertTrue(comment.contains("Steps: 4"))
        XCTAssertTrue(comment.contains("Quantization: 4"))
        XCTAssertTrue(comment.contains("LoRA: F2K9B_BallgagV2_2020E10 [1]"))
        XCTAssertTrue(comment.contains("Prompt:"))
        XCTAssertTrue(comment.contains("scene"))
        XCTAssertFalse(comment.contains("{"))

        let finalStyle = ImageGenGenerationExifService.formatGenerationExifComment(
            pluginID: "flux_klein_9b_kv_create",
            values: values,
            workerResult: ["seed": 1_335_284_087],
            elapsedSeconds: 42,
            lora: "F2K9B_BallgagV2_2020E10 [1]"
        )
        XCTAssertEqual(
            comment.components(separatedBy: "\n\nPrompt:").first,
            finalStyle.components(separatedBy: "\n\nPrompt:").first
        )
    }

    @MainActor
    func testProgressiveExifRewritesElapsedWhenLoraLinePresent() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("progressive-exif-elapsed-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }

        let output = (dir as NSString).appendingPathComponent("imagegen-0003.webp")
        try writeMinimalPNG(at: output)

        let values: [String: Any] = [
            "prompt": "scene",
            "seed": 42,
            "steps": 4,
            "mflux_quantize": 4,
            "hf_model_id": LoRAHFModelIDs.flux2Klein9BKV,
            "mflux_lora_stack": ["BallgagV2"],
            "mflux_lora_scales": [1.0],
        ]
        let lora = "F2K9B_BallgagV2_2020E10 [1]"

        _ = try await ImageGenGenerationExifService.makeReadableUserCommentBeforeBrowse(
            pluginID: "flux_klein_9b_kv_create",
            outputPath: output,
            values: values,
            elapsedSeconds: 10,
            completedStep: 1,
            totalSteps: 4,
            fallbackSourcePaths: [],
            tempRoot: dir,
            lora: lora
        )
        _ = try await ImageGenGenerationExifService.makeReadableUserCommentBeforeBrowse(
            pluginID: "flux_klein_9b_kv_create",
            outputPath: output,
            values: values,
            elapsedSeconds: 99,
            completedStep: 2,
            totalSteps: 4,
            fallbackSourcePaths: [],
            tempRoot: dir,
            lora: lora
        )

        let comment = ExifService.userComment(path: output) ?? ""
        XCTAssertTrue(comment.contains("Elapsed: 1:39"))
        XCTAssertTrue(comment.contains("LoRA: F2K9B_BallgagV2_2020E10 [1]"))
    }

    @MainActor
    func testProgressiveExifPreservesSeedAfterFormattedRewrite() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("progressive-exif-seed-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }

        let output = (dir as NSString).appendingPathComponent("imagegen-seed.webp")
        try writeMinimalPNG(at: output)

        let values: [String: Any] = [
            "prompt": "cat",
            "random_seed": true,
            "seed": 0,
            "steps": 4,
            "hf_model_id": LoRAHFModelIDs.flux2Klein9BKV,
        ]

        _ = try await ImageGenGenerationExifService.makeReadableUserCommentBeforeBrowse(
            pluginID: "flux_klein_9b_kv_create",
            outputPath: output,
            values: values,
            elapsedSeconds: 5,
            completedStep: 1,
            totalSteps: 4,
            fallbackSourcePaths: [],
            tempRoot: dir,
            supplementalWorkerResult: ["seed": 9_876_543_210]
        )

        let comment = ExifService.userComment(path: output) ?? ""
        XCTAssertTrue(comment.contains("Seed: 9876543210"))
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
            throw NSError(domain: "ExifProgressivePreviewTests", code: 1)
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "ExifProgressivePreviewTests", code: 2)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "ExifProgressivePreviewTests", code: 3)
        }
    }
}
