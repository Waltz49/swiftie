import XCTest
@testable import Prowser

@MainActor
final class ImageGenPipelineRoutingTests: XCTestCase {
    private func config(withBackend backend: String) -> AppConfig {
        let config = ProwserTestSupport.ephemeralAppConfig()
        config.updateSetting("imagegen_execution_backend", value: backend)
        return config
    }

    func testDiffusersPipelinesUseOptimizedWorkerByDefault() {
        for pipeline in ImageGenPipelineRouting.diffusersPipelineIDs {
            XCTAssertFalse(MfluxCLIPipeline.isSupported(pipelineID: pipeline), pipeline)
            XCTAssertTrue(
                ImageGenPipelineRouting.usesPythonWorker(pipelineID: pipeline, hfModelID: ""),
                pipeline
            )
            XCTAssertEqual(
                ImageGenPipelineRouting.executionKind(pipelineID: pipeline, hfModelID: ""),
                .optimizedPythonWorker,
                pipeline
            )
        }
    }

    func testMfluxPipelinesUseOptimizedWorkerByDefault() {
        let mflux: [String] = [
            "flux_schnell_mflux_play",
            "mflux_z_image_turbo",
            "mflux_fill_expand",
            "mflux_fill_infill",
            "mflux_flux2_klein_create",
            "mflux_flux2_klein_edit",
            "mflux_flux2_klein_expand",
        ]
        for pipeline in mflux {
            XCTAssertTrue(MfluxCLIPipeline.isSupported(pipelineID: pipeline), pipeline)
            XCTAssertTrue(
                ImageGenPipelineRouting.usesPersistentPythonWorker(
                    pipelineID: pipeline,
                    hfModelID: "black-forest-labs/FLUX.1-schnell"
                ),
                pipeline
            )
            XCTAssertEqual(
                ImageGenPipelineRouting.executionKind(
                    pipelineID: pipeline,
                    hfModelID: "black-forest-labs/FLUX.1-schnell"
                ),
                .optimizedPythonWorker,
                pipeline
            )
        }
    }

    func testMfluxCLIPipelinesWhenBackendIsCLI() {
        let config = config(withBackend: "mflux_cli")
        let cli: [String] = [
            "flux_schnell_mflux_play",
            "mflux_z_image_turbo",
            "mflux_fill_expand",
            "mflux_fill_infill",
            "mflux_flux2_klein_create",
            "mflux_flux2_klein_edit",
            "mflux_flux2_klein_expand",
        ]
        for pipeline in cli {
            XCTAssertEqual(
                ImageGenPipelineRouting.executionKind(
                    pipelineID: pipeline,
                    hfModelID: "black-forest-labs/FLUX.1-schnell",
                    config: config
                ),
                .mfluxCLI,
                pipeline
            )
            XCTAssertFalse(
                ImageGenPipelineRouting.usesPythonWorker(
                    pipelineID: pipeline,
                    hfModelID: "black-forest-labs/FLUX.1-schnell",
                    config: config
                ),
                pipeline
            )
        }
    }

    func testExecutionBackendFromConfig() {
        XCTAssertEqual(ImageGenExecutionBackend.from(config: config(withBackend: "optimized")), .optimized)
        XCTAssertEqual(ImageGenExecutionBackend.from(config: config(withBackend: "mflux_cli")), .mfluxCLI)
    }

    func testFillCLIReceivesPreparedImageDimensions() throws {
        let args = try MfluxCLIPipeline.buildArguments(payload: [
            "pipeline_id": "mflux_fill_infill",
            "output_path": "/tmp/output.png",
            "source_image_path": "/tmp/base.png",
            "mask_image_path": "/tmp/mask.png",
            "width": 256,
            "height": 256,
        ])

        XCTAssertEqual(args[args.firstIndex(of: "--width")! + 1], "256")
        XCTAssertEqual(args[args.firstIndex(of: "--height")! + 1], "256")
    }

    func testAvailableMfluxCLIsDoNotReceiveUnsupportedNoBakeLoraFlag() throws {
        let payloads: [[String: Any]] = [
            [
                "pipeline_id": "flux_schnell_mflux_play",
                "prompt": "test",
                "output_path": "/tmp/output.png",
            ],
            [
                "pipeline_id": "mflux_z_image_turbo",
                "prompt": "test",
                "output_path": "/tmp/output.png",
            ],
            [
                "pipeline_id": "mflux_fill_expand",
                "prompt": "test",
                "output_path": "/tmp/output.png",
                "source_image_path": "/tmp/source.png",
            ],
            [
                "pipeline_id": "mflux_flux2_klein_create",
                "prompt": "test",
                "output_path": "/tmp/output.png",
                "hf_model_id": "black-forest-labs/FLUX.2-klein-4B",
            ],
            [
                "pipeline_id": "mflux_flux2_klein_edit",
                "prompt": "test",
                "output_path": "/tmp/output.png",
                "source_image_path": "/tmp/source.png",
                "hf_model_id": "black-forest-labs/FLUX.2-klein-4B",
            ],
        ]

        for payload in payloads {
            var withLora = payload
            withLora["mflux_lora_paths"] = ["/tmp/test.safetensors"]

            XCTAssertFalse(try MfluxCLIPipeline.buildArguments(payload: payload).contains("--no-bake-lora"))
            let loraArgs = try MfluxCLIPipeline.buildArguments(payload: withLora)
            XCTAssertFalse(loraArgs.contains("--no-bake-lora"))
            XCTAssertTrue(loraArgs.contains("--lora-paths"))
        }

        let kleinEditArgs = try MfluxCLIPipeline.buildArguments(payload: [
            "pipeline_id": "mflux_flux2_klein_edit",
            "prompt": "test",
            "output_path": "/tmp/output.png",
            "source_image_path": "/tmp/source.png",
            "hf_model_id": "black-forest-labs/FLUX.2-klein-4B",
        ])
        XCTAssertTrue(kleinEditArgs.contains("--image-paths"))
        XCTAssertFalse(kleinEditArgs.contains("--image-path"))
    }

    func testSceneWorksUsesOptimizedWorker() {
        let repo = ImageGenSceneWorksKlein.repoID
        XCTAssertTrue(
            ImageGenPipelineRouting.usesPythonWorker(
                pipelineID: "mflux_flux2_klein_create",
                hfModelID: repo
            )
        )
        XCTAssertEqual(
            ImageGenPipelineRouting.executionKind(pipelineID: "mflux_flux2_klein_create", hfModelID: repo),
            .optimizedPythonWorker
        )
    }

    func testRealisticVisionPipelineIsSD15Python() {
        XCTAssertTrue(ImageGenPipelineRouting.diffusersPipelineIDs.contains("sd15_diffusers"))
    }

    func testZImageCLIIncludesModelForFilipstrandOnly() throws {
        let base: [String: Any] = [
            "pipeline_id": "mflux_z_image_turbo",
            "prompt": "test",
            "output_path": "/tmp/output.png",
            "mflux_quantize": 4,
        ]
        let filipstrand = base.merging(["hf_model_id": LoRAHFModelIDs.zImageTurboMflux4Bit]) { $1 }
        let tongyi = base.merging(["hf_model_id": LoRAHFModelIDs.zImageTurbo]) { $1 }

        let filipArgs = try MfluxCLIPipeline.buildArguments(payload: filipstrand)
        XCTAssertTrue(filipArgs.contains("--model"))
        XCTAssertTrue(filipArgs.contains(LoRAHFModelIDs.zImageTurboMflux4Bit))

        let tongyiArgs = try MfluxCLIPipeline.buildArguments(payload: tongyi)
        XCTAssertFalse(tongyiArgs.contains("--model"))
    }
}
