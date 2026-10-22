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
        let contPrefix = String(repeating: " ", count: 6)
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
        XCTAssertTrue(comment.contains("LoRA: My LoRA [1] + Other [0.5]"))
    }

    @MainActor
    func testParseExifLoraContinuationNBSPForImportRest() {
        let nbsp = String(repeating: "\u{00a0}", count: 6)
        let comment = """
        Image Model:
        FLUX.2 Klein 9B KV
        LoRA: First [1]
        \(nbsp)Second [0.5]

        Prompt:
        cat
        """
        let parsed = ImageGenExifImport.parseExifGenerationMetadata(comment)
        XCTAssertEqual(parsed["lora"] as? String, "First [1] + Second [0.5]")
    }

    @MainActor
    func testMergingPluginDefaultsPreservesCopies() {
        let defaults: [String: Any] = ["copies": 1, "steps": 4, "width": 512]
        let values: [String: Any] = ["copies": 5, "steps": 20, "width": 1024, "prompt": "keep"]
        let merged = ImageGenExifImport.mergingPluginDefaults(defaults, preserving: values)
        XCTAssertEqual(merged["copies"] as? Int, 5)
        XCTAssertEqual(merged["steps"] as? Int, 4)
        XCTAssertEqual(merged["width"] as? Int, 1024)
        XCTAssertEqual(merged["prompt"] as? String, "keep")
    }

    @MainActor
    func testImportRestResolvesGeneratedExifModelLabel() {
        let plugins: [[String: Any]] = [[
            "plugin_id": "flux_schnell_mflux",
            "display_name": "FLUX.1 Schnell MFLUX",
            "model_label": "FLUX.1 Schnell MFLUX",
            "hf_model_id": "black-forest-labs/FLUX.1-schnell",
            "pipeline_id": "flux_schnell_mflux_play",
            "available": true,
        ]]

        XCTAssertEqual(
            ImageGenExifImport.resolvePluginID(
                forExifModel: "FLUX.1 Schnell",
                plugins: plugins
            ),
            "flux_schnell_mflux"
        )
    }

    @MainActor
    func testImportRestResolvesSceneWorksGeneratedExifModelLabel() {
        let plugins: [[String: Any]] = [[
            "plugin_id": "sceneworks_klein_9b_kv_mlx_create",
            "display_name": "SceneWorks/flux2-klein-9b-kv-mlx",
            "model_label": "flux2-klein-9b-kv-mlx",
            "hf_model_id": "SceneWorks/flux2-klein-9b-kv-mlx",
            "pipeline_id": "mflux_flux2_klein_create",
            "available": true,
        ]]

        XCTAssertEqual(
            ImageGenExifImport.resolvePluginID(
                forExifModel: "FLUX 2 Klein 9B KV MLX",
                plugins: plugins
            ),
            "sceneworks_klein_9b_kv_mlx_create"
        )

        let comment = """
        Image Model:
        FLUX 2 Klein 9B KV MLX
        Seed: 1335284087
        Steps: 4
        LoRA: F2K9B_BallgagV2_2020E10 [1]
        Guidance: 7

        Prompt:
        test
        """
        let parsed = ImageGenExifImport.parseExifGenerationMetadata(comment)
        XCTAssertEqual(parsed["model"] as? String, "FLUX 2 Klein 9B KV MLX")
        XCTAssertEqual(parsed["lora"] as? String, "F2K9B_BallgagV2_2020E10 [1]")
        XCTAssertEqual(parsed["seed"] as? Int, 1_335_284_087)
    }
}
