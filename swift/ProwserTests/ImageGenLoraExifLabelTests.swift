import XCTest
@testable import Prowser

final class ImageGenLoraExifLabelTests: XCTestCase {
    func testLoraNameFromStackAndSnapshottedPaths() {
        let values: [String: Any] = [
            "mflux_lora_stack": ["sample_lora"],
            "mflux_lora_paths": ["/cache/mflux_loras/sample_lora.safetensors"],
            "mflux_lora_scales": [0.85],
        ]
        let label = ImageGenExifCommentFormatting.loraNameForExifFromValues(
            values: values,
            pipelineID: "flux_schnell_mflux",
            loraHostID: "flux1_t2i"
        )
        XCTAssertEqual(label, "sample_lora [0.85]")
    }

    func testLoraNameFromSd15SinglePreset() {
        let values: [String: Any] = [
            "mflux_lora": "furry_lora",
            "sd15_lora_paths": ["/loras/furry_lora.safetensors"],
            "sd15_lora_scales": [1.0],
        ]
        let label = ImageGenExifCommentFormatting.loraNameForExifFromValues(
            values: values,
            pipelineID: "realistic_vision_v4_sd15",
            loraHostID: "sd15"
        )
        XCTAssertEqual(label, "furry_lora [1]")
    }

    func testNormalizeExifLoraDisplayLinesSplitsStack() {
        let raw = """
        Image Model:
        FLUX.1 Dev
        LoRA: First [1] + Second [0.5]
        Steps: 20

        Prompt:
        cat
        """
        let normalized = ImageGenExifCommentFormatting.normalizeExifLoraDisplayLines(raw)
        XCTAssertTrue(normalized.contains("LoRA: First [1]"))
        let contPrefix = String(repeating: "\u{00a0}", count: 6)
        XCTAssertTrue(normalized.contains("\(contPrefix)Second [0.5]"))
    }

    func testExifPromptIncludesLoraLines() {
        let comment = ImageGenExifCommentFormatting.formatImageExifPrompt(
            modelName: "FLUX.1 Dev",
            promptText: "a cat",
            seed: 1,
            steps: 20,
            quantization: 4,
            lora: "My LoRA [1] + Other [0.5]"
        )
        XCTAssertTrue(comment.contains("LoRA: My LoRA [1]"))
        XCTAssertTrue(comment.contains("\u{00a0}\u{00a0}\u{00a0}\u{00a0}\u{00a0}\u{00a0}Other [0.5]"))
    }
}
