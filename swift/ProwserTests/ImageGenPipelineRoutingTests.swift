import XCTest
@testable import Prowser

final class ImageGenPipelineRoutingTests: XCTestCase {
    func testBundledPythonPipelinesDoNotRequireMfluxCLIAtStart() {
        let pythonPipelines = ImageGenPipelineRouting.bundledPythonWorkerPipelineIDs
        for pipeline in pythonPipelines {
            XCTAssertFalse(MfluxCLIPipeline.isSupported(pipelineID: pipeline), pipeline)
            XCTAssertTrue(
                ImageGenPipelineRouting.usesPythonWorker(pipelineID: pipeline, hfModelID: ""),
                pipeline
            )
            XCTAssertEqual(
                ImageGenPipelineRouting.executionKind(pipelineID: pipeline, hfModelID: ""),
                .bundledPythonWorker,
                pipeline
            )
        }
    }

    func testMfluxCLIPipelines() {
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
            XCTAssertTrue(MfluxCLIPipeline.isSupported(pipelineID: pipeline), pipeline)
            XCTAssertFalse(
                ImageGenPipelineRouting.usesPythonWorker(
                    pipelineID: pipeline,
                    hfModelID: "black-forest-labs/FLUX.1-schnell"
                ),
                pipeline
            )
        }
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
    }

    func testSceneWorksUsesPythonWorkerDespiteKleinPipeline() {
        let repo = ImageGenSceneWorksKlein.repoID
        XCTAssertTrue(
            ImageGenPipelineRouting.usesPythonWorker(
                pipelineID: "mflux_flux2_klein_create",
                hfModelID: repo
            )
        )
        XCTAssertEqual(
            ImageGenPipelineRouting.executionKind(pipelineID: "mflux_flux2_klein_create", hfModelID: repo),
            .sceneWorksPythonWorker
        )
    }

    func testRealisticVisionPipelineIsSD15Python() {
        XCTAssertTrue(
            ImageGenPipelineRouting.bundledPythonWorkerPipelineIDs.contains("sd15_diffusers")
        )
    }
}
