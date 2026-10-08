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
