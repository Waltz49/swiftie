import CoreGraphics
import ImageIO
import XCTest
@testable import Prowser

final class ImageGenWorkerPayloadBuilderTests: XCTestCase {
    @MainActor
    func testEnqueueSubmitRestoresDialogSeriesRefinementAfterStrip() {
        var submit: [String: Any] = [
            "prompt": "test",
            "series_refinement": true,
            "copies": 3,
        ]
        let flags = ImageGenJobValuesSnapshot.jobQueueOnlyKeysPresent(in: submit)
        ImageGenJobValuesSnapshot.stripDialogLeakedJobQueueFlags(&submit)
        XCTAssertNil(submit["series_refinement"])
        ImageGenJobValuesSnapshot.applyJobQueueOnlyKeys(values: &submit, from: flags)
        XCTAssertEqual(submit["series_refinement"] as? Bool, true)
    }

    @MainActor
    func testReplaceSubmitPreservesThenAppliesDialogSeriesRefinement() {
        var snapshotted: [String: Any] = ["prompt": "x", "copies": 2]
        let prior: [String: Any] = ["series_refinement": true]
        let dialog: [String: Any] = ["series_refinement": false]
        ImageGenJobValuesSnapshot.preserveJobQueueOnlyKeys(values: &snapshotted, source: prior)
        XCTAssertEqual(snapshotted["series_refinement"] as? Bool, true)
        ImageGenJobValuesSnapshot.applyJobQueueOnlyKeys(values: &snapshotted, from: dialog)
        XCTAssertEqual(snapshotted["series_refinement"] as? Bool, false)
    }

    @MainActor
    func testSnapshotJobValuesPreservesSeriesRefinement() async throws {
        let config = ProwserTestSupport.ephemeralAppConfig()
        guard let plugin = ImageGenPluginCatalog.plugin(pluginID: "flux_schnell_mflux") else {
            XCTFail("missing plugin")
            return
        }
        let snap = try await ImageGenJobValuesSnapshot.snapshotJobValuesAtSubmit(
            plugin: plugin,
            values: [
                "prompt": "test",
                "series_refinement": true,
                "copies": 3,
            ],
            config: config
        )
        XCTAssertEqual(snap["series_refinement"] as? Bool, true)
    }

    @MainActor
    func testFluxSchnellPayloadMatchesGolden() async throws {
        let config = ProwserTestSupport.ephemeralAppConfig()
        config.setValue(false, forKey: "debug_mode")
        config.setValue(true, forKey: "imagegen_low_ram")
        var imagegen: [String: Any] = [:]
        imagegen["show_progressive_images"] = true
        config.updateSetting("imagegen", value: imagegen)

        guard let plugin = ImageGenPluginCatalog.plugin(pluginID: "flux_schnell_mflux") else {
            XCTFail("missing plugin")
            return
        }
        let snap = try await ImageGenJobValuesSnapshot.snapshotJobValuesAtSubmit(
            plugin: plugin,
            values: [
                "prompt": "test",
                "width": 1024,
                "height": 1024,
                "steps": 4,
                "mflux_quantize": 4,
            ],
            config: config
        )
        let outputPath = "/tmp/out.png"
        let payload = try ImageGenWorkerPayloadBuilder.build(
            plugin: plugin,
            values: snap,
            outputPath: outputPath,
            config: config,
            applyImageExit: false
        )
        let goldenURL = Bundle.module.url(
            forResource: "flux_schnell_mflux",
            withExtension: "json",
            subdirectory: "ImageGenPayloadGolden"
        )
        guard let goldenURL,
              let data = try? Data(contentsOf: goldenURL),
              let golden = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("missing golden fixture")
            return
        }
        assertPayloadSubset(payload, matches: golden, ignoring: ["output_path"])
    }

    @MainActor
    func testFluxDevPluginPayloadUsesDevHFModelID() async throws {
        let config = ProwserTestSupport.ephemeralAppConfig()
        config.setValue(false, forKey: "debug_mode")
        guard let plugin = ImageGenPluginCatalog.plugin(pluginID: "flux_sldr_nsfw_v2_lora") else {
            XCTFail("missing plugin")
            return
        }
        XCTAssertEqual(plugin.hfModelID, LoRAHFModelIDs.flux1Dev)
        let snap = try await ImageGenJobValuesSnapshot.snapshotJobValuesAtSubmit(
            plugin: plugin,
            values: [
                "prompt": "test",
                "width": 1024,
                "height": 1024,
                "steps": 20,
                "mflux_quantize": 4,
            ],
            config: config
        )
        let payload = try ImageGenWorkerPayloadBuilder.build(
            plugin: plugin,
            values: snap,
            outputPath: "/tmp/out.png",
            config: config,
            applyImageExit: false
        )
        XCTAssertEqual(payload["hf_model_id"] as? String, LoRAHFModelIDs.flux1Dev)
    }

    @MainActor
    func testStaleJobValuesHFModelIDDoesNotOverridePluginOnPayload() throws {
        let config = ProwserTestSupport.ephemeralAppConfig()
        guard let plugin = ImageGenPluginCatalog.plugin(pluginID: "flux_sldr_nsfw_v2_lora") else {
            XCTFail("missing plugin")
            return
        }
        let payload = try ImageGenWorkerPayloadBuilder.build(
            plugin: plugin,
            values: [
                "prompt": "test",
                "width": 1024,
                "height": 1024,
                "steps": 20,
                "hf_model_id": "black-forest-labs/FLUX.1-schnell",
                "_job_values_snapshotted": true,
            ],
            outputPath: "/tmp/out.png",
            config: config,
            applyImageExit: false
        )
        XCTAssertEqual(payload["hf_model_id"] as? String, LoRAHFModelIDs.flux1Dev)
    }

    @MainActor
    func testSnapshotSubmitStampsPluginHFModelIDOverStaleValues() async throws {
        let config = ProwserTestSupport.ephemeralAppConfig()
        guard let plugin = ImageGenPluginCatalog.plugin(pluginID: "flux_sldr_nsfw_v2_lora") else {
            XCTFail("missing plugin")
            return
        }
        let snap = try await ImageGenJobValuesSnapshot.snapshotJobValuesAtSubmit(
            plugin: plugin,
            values: [
                "prompt": "test",
                "width": 1024,
                "height": 1024,
                "steps": 20,
                "hf_model_id": "black-forest-labs/FLUX.1-schnell",
            ],
            config: config
        )
        XCTAssertEqual(snap["hf_model_id"] as? String, LoRAHFModelIDs.flux1Dev)
    }

    @MainActor
    func testInfillPayloadSetsCanonicalFromPixelmatorDocPath() throws {
        let fm = FileManager.default
        let dataDir = fm.temporaryDirectory.appendingPathComponent("infill-payload-\(UUID().uuidString)")
        let config = ProwserTestSupport.ephemeralAppConfig(profileRoot: dataDir)
        let tempRoot = config.temporaryFilesDirectory.path
        let libraryDir = fm.temporaryDirectory.appendingPathComponent("infill-canonical-lib-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: libraryDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: libraryDir) }

        let docPath = (libraryDir as NSString).appendingPathComponent("original.webp")
        let basePath = (tempRoot as NSString).appendingPathComponent("infill-base.png")
        let maskPath = (tempRoot as NSString).appendingPathComponent("infill-mask.png")
        try fm.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)
        XCTAssertTrue(fm.createFile(atPath: docPath, contents: Data([0x00])))
        XCTAssertTrue(fm.createFile(atPath: basePath, contents: Data([0x00])))
        XCTAssertTrue(fm.createFile(atPath: maskPath, contents: Data([0x00])))

        guard let plugin = ImageGenPluginCatalog.plugin(pluginID: "flux_fill_infill") else {
            XCTFail("missing plugin")
            return
        }
        let payload = try ImageGenWorkerPayloadBuilder.build(
            plugin: plugin,
            values: [
                "prompt": "fill",
                "pixelmator_doc_path": docPath,
                "pixelmator_base_path": basePath,
                "pixelmator_mask_path": maskPath,
                "source_image_path": basePath,
                "width": 512,
                "height": 512,
                "steps": 20,
            ],
            outputPath: (tempRoot as NSString).appendingPathComponent("out.png"),
            config: config,
            applyImageExit: false
        )
        let canonical = payload["_canonical_source_image_paths"] as? [String]
        XCTAssertEqual(canonical?.count, 1)
        XCTAssertEqual(
            canonical?.first,
            URL(fileURLWithPath: docPath).standardizedFileURL.path
        )
    }

    @MainActor
    func testZImagePayloadUsesPluginHfModelIDWithoutQuantRouting() throws {
        let config = ProwserTestSupport.ephemeralAppConfig()
        for pluginID in ["z_image_turbo_mflux_4bit", "z_image_turbo_mflux"] {
            guard let plugin = ImageGenPluginCatalog.plugin(pluginID: pluginID) else {
                XCTFail("missing \(pluginID)")
                continue
            }
            let payload = try ImageGenWorkerPayloadBuilder.build(
                plugin: plugin,
                values: ["prompt": "z", "width": 1024, "height": 1024, "steps": 9],
                outputPath: "/tmp/z.png",
                config: config,
                applyImageExit: false
            )
            XCTAssertEqual(payload["hf_model_id"] as? String, plugin.hfModelID, pluginID)
        }
    }

    @MainActor
    func testEditSnapshotReplacesStaleCanonicalSourcePaths() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("edit-snapshot-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let intended = dir.appendingPathComponent("intended.png").path
        let stale = dir.appendingPathComponent("stale.png").path
        XCTAssertTrue(fm.createFile(atPath: intended, contents: Data([0x00])))
        XCTAssertTrue(fm.createFile(atPath: stale, contents: Data([0x00])))

        guard let plugin = ImageGenPluginCatalog.plugin(pluginID: "sceneworks_klein_9b_kv_mlx_edit") else {
            XCTFail("missing plugin")
            return
        }
        let config = ProwserTestSupport.ephemeralAppConfig(profileRoot: dir)
        let snapshot = try await ImageGenJobValuesSnapshot.snapshotJobValuesAtSubmit(
            plugin: plugin,
            values: [
                "source_image_path": intended,
                "source_image_paths": [intended],
                "_canonical_source_image_paths": [stale],
            ],
            config: config
        )

        XCTAssertEqual(snapshot["source_image_paths"] as? [String], [intended])
        XCTAssertEqual(snapshot["_canonical_source_image_paths"] as? [String], [intended])
        XCTAssertEqual(
            JobCardThumbnailPaths.paths(pluginID: plugin.pluginID, values: snapshot),
            [intended]
        )
    }

    @MainActor
    func testReplaceSubmitHonorsNSNumberCustomSize() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("klein-replace-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let source = dir.appendingPathComponent("source.png").path
        XCTAssertTrue(createSolidPNG(at: source, width: 64, height: 64))

        var dialogSubmit: [String: Any] = [
            "prompt": "edit",
            "source_image_path": source,
            "source_image_paths": [source],
            "use_custom_size": NSNumber(value: true),
            "width": NSNumber(value: 256),
            "height": NSNumber(value: 256),
            "aspect_ratio_test": false,
            "steps": 4,
        ]
        ImageGenEditCustomSizeSubmit.normalizeOptionalCustomSizeFields(&dialogSubmit)

        let config = ProwserTestSupport.ephemeralAppConfig(profileRoot: dir)
        guard let plugin = ImageGenPluginCatalog.plugin(pluginID: "flux_klein_4b_edit") else {
            XCTFail("missing plugin")
            return
        }
        let payload = try ImageGenWorkerPayloadBuilder.build(
            plugin: plugin,
            values: dialogSubmit,
            outputPath: dir.appendingPathComponent("out.png").path,
            config: config,
            applyImageExit: false
        )
        let paths = payload["source_image_paths"] as? [String]
        XCTAssertEqual(paths?.count, 1)
        XCTAssertNotEqual(paths?.first, source)
    }

    @MainActor
    func testKleinEditMultiImageCustomSizeAndAspectPadding() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("klein-edit-multi-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let first = dir.appendingPathComponent("first.png").path
        let second = dir.appendingPathComponent("second.png").path
        XCTAssertTrue(createSolidPNG(at: first, width: 96, height: 48))
        XCTAssertTrue(createSolidPNG(at: second, width: 48, height: 96))

        let config = ProwserTestSupport.ephemeralAppConfig(profileRoot: dir)
        guard let plugin = ImageGenPluginCatalog.plugin(pluginID: "flux_klein_4b_edit") else {
            XCTFail("missing plugin")
            return
        }
        let payload = try ImageGenWorkerPayloadBuilder.build(
            plugin: plugin,
            values: [
                "prompt": "edit",
                "source_image_path": first,
                "source_image_paths": [first, second],
                "use_custom_size": true,
                "width": 192,
                "height": 192,
                "aspect_ratio_test": true,
                "steps": 4,
            ],
            outputPath: dir.appendingPathComponent("out.png").path,
            config: config,
            applyImageExit: false
        )
        let generatorPaths = payload["source_image_paths"] as? [String]
        XCTAssertEqual(generatorPaths?.count, 2)
        XCTAssertNotEqual(generatorPaths?[0], first)
        XCTAssertNotEqual(generatorPaths?[1], second)
        let canonical = payload["_canonical_source_image_paths"] as? [String]
        XCTAssertEqual(canonical, [first, second])
        let padTemps = payload["_aspect_pad_temp_paths"] as? [String] ?? []
        XCTAssertGreaterThanOrEqual(padTemps.count, 2)
        for path in generatorPaths ?? [] {
            XCTAssertEqual(ImageRecognitionImageLoader.orientedPixelSize(path: path)?.width, 192)
            XCTAssertEqual(ImageRecognitionImageLoader.orientedPixelSize(path: path)?.height, 192)
        }

        let prepped = try await ImageGenMfluxPrep.apply(to: payload)
        let cliSources = prepped["source_image_paths"] as? [String]
        XCTAssertEqual(cliSources?.count, 2)
        XCTAssertEqual(cliSources, generatorPaths)
    }

    @MainActor
    func testKleinEditCustomSizePadsFirstSourcePath() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("klein-edit-pad-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let source = dir.appendingPathComponent("source.png").path
        XCTAssertTrue(createSolidPNG(at: source, width: 64, height: 32))

        let config = ProwserTestSupport.ephemeralAppConfig(profileRoot: dir)
        guard let plugin = ImageGenPluginCatalog.plugin(pluginID: "flux_klein_4b_edit") else {
            XCTFail("missing plugin")
            return
        }
        let payload = try ImageGenWorkerPayloadBuilder.build(
            plugin: plugin,
            values: [
                "prompt": "edit",
                "source_image_path": source,
                "source_image_paths": [source],
                "use_custom_size": true,
                "width": 128,
                "height": 128,
                "aspect_ratio_test": false,
                "steps": 4,
            ],
            outputPath: dir.appendingPathComponent("out.png").path,
            config: config,
            applyImageExit: false
        )
        let generatorPaths = payload["source_image_paths"] as? [String]
        XCTAssertEqual(generatorPaths?.count, 1)
        XCTAssertNotEqual(generatorPaths?.first, source)
        let padTemps = payload["_aspect_pad_temp_paths"] as? [String]
        XCTAssertEqual(padTemps?.count, 1)
        XCTAssertEqual(padTemps?.first, generatorPaths?.first)
        XCTAssertNil(payload["width"])
        XCTAssertNil(payload["use_custom_size"])
    }

    @MainActor
    func testFillExpandPrepSetsPreparedBaseAndKeepsOriginalSourceForWorker() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("fill-expand-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let source = dir.appendingPathComponent("source.png").path
        let output = dir.appendingPathComponent("imagegen-fill.webp").path
        XCTAssertTrue(createSolidPNG(at: source, width: 64, height: 48))

        let payload: [String: Any] = [
            "pipeline_id": "mflux_fill_expand",
            "source_image_path": source,
            "output_path": output,
            "width": 256,
            "height": 192,
            "placement_x": 12,
            "placement_y": 8,
            "placement_w": 128,
            "placement_h": 96,
            "steps": 20,
            "prompt": "outfill",
            "random_seed": false,
            "seed": 3,
        ]
        let prepped = try await ImageGenMfluxPrep.apply(to: payload)
        XCTAssertEqual(prepped["source_image_path"] as? String, source)
        let prepared = prepped["prepared_fill_image_path"] as? String ?? ""
        XCTAssertTrue(prepared.contains("imagegen-expand-base-"))
        XCTAssertTrue(fm.fileExists(atPath: prepared))
        let mask = prepped["mask_image_path"] as? String ?? ""
        XCTAssertTrue(mask.contains("imagegen-expand-mask-"))
        XCTAssertTrue(fm.fileExists(atPath: mask))

        var cliPayload = prepped
        ImageGenMfluxPrep.usePreparedFillBaseForCLIIfNeeded(&cliPayload)
        XCTAssertEqual(cliPayload["source_image_path"] as? String, prepared)
        XCTAssertEqual(cliPayload["mask_image_path"] as? String, mask)
    }

    @MainActor
    func testPythonOwnedKleinExpandPreparesCompositeForWorker() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("klein-expand-own-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let source = dir.appendingPathComponent("source.png").path
        let output = dir.appendingPathComponent("imagegen-5818.webp").path
        XCTAssertTrue(createSolidPNG(at: source, width: 64, height: 32))

        let payload: [String: Any] = [
            "pipeline_id": "mflux_flux2_klein_expand",
            "source_image_path": source,
            "output_path": output,
            "width": 128,
            "height": 64,
            "placement_x": 8,
            "placement_y": 4,
            "placement_w": 64,
            "placement_h": 32,
            "steps": 4,
            "prompt": "Extend the image only into the gray border areas",
            "random_seed": false,
            "seed": 7,
        ]
        let prepped = try await ImageGenMfluxPrep.apply(to: payload)
        let workerSource = prepped["source_image_path"] as? String ?? ""
        XCTAssertNotEqual(workerSource, source)
        XCTAssertTrue(workerSource.contains("imagegen-klein-expand-composite-"))
        XCTAssertTrue(fm.fileExists(atPath: workerSource))
        XCTAssertNotEqual(prepped["output_path"] as? String, output)
        let post = prepped["_klein_expand_post"] as? [String: String]
        XCTAssertEqual(post?["final_output"], output)
        XCTAssertNil(post?["background"])
        XCTAssertNil(post?["mask"])
        XCTAssertEqual(prepped["progressive_output_path"] as? String, output)
        XCTAssertNotEqual(prepped["output_path"] as? String, output)
    }

    @MainActor
    func testKleinExpandFinalizePassesThroughGeneratedWithoutPhotoPaste() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("klein-expand-keep-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let generated = solidImage(width: 160, height: 120, red: 0, green: 255, blue: 0)
        let genPath = dir.appendingPathComponent("gen.png").path
        let finalPath = dir.appendingPathComponent("out.png").path
        XCTAssertTrue(ImageGenOutpaintMask.savePNG(generated, path: genPath))

        let payload: [String: Any] = [
            "pipeline_id": "mflux_flux2_klein_expand",
            "_klein_expand_post": ["final_output": finalPath],
        ]
        let written = try ImageGenMfluxPrep.finalizeKleinExpandIfNeeded(payload: payload, cliOutputPath: genPath)
        XCTAssertEqual(written, finalPath)
        guard let out = ImageGenOutpaintMask.loadRasterCGImage(path: finalPath) else {
            XCTFail("missing final output")
            return
        }
        let sample = rgb(out, x: 50, yTop: 40)
        XCTAssertGreaterThan(sample.1, 200, "finalize should keep model green \(sample)")
        XCTAssertLessThan(sample.0, 40, "finalize should not paste red source \(sample)")
    }

    @MainActor
    func testKleinExpandFinalizeWritesWebPAndKeepsSamePath() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("klein-expand-final-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let generated = dir.appendingPathComponent("generated.png").path
        let finalWebp = dir.appendingPathComponent("imagegen-5818.webp").path
        XCTAssertTrue(createSolidPNG(at: generated, width: 32, height: 32))

        let meta: [String: String] = ["final_output": finalWebp]
        let payload: [String: Any] = [
            "pipeline_id": "mflux_flux2_klein_expand",
            "_klein_expand_post": meta,
        ]
        let written = try ImageGenMfluxPrep.finalizeKleinExpandIfNeeded(
            payload: payload,
            cliOutputPath: generated
        )
        XCTAssertEqual(written, finalWebp)
        XCTAssertTrue(fm.fileExists(atPath: finalWebp))
        let size = (try? fm.attributesOfItem(atPath: finalWebp)[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(size, 32)
        XCTAssertFalse(fm.fileExists(atPath: generated))

        let same = dir.appendingPathComponent("same.png").path
        XCTAssertTrue(createSolidPNG(at: same, width: 32, height: 32))
        let sameMeta: [String: String] = ["final_output": same]
        let samePayload: [String: Any] = [
            "pipeline_id": "mflux_flux2_klein_expand",
            "_klein_expand_post": sameMeta,
        ]
        let kept = try ImageGenMfluxPrep.finalizeKleinExpandIfNeeded(
            payload: samePayload,
            cliOutputPath: same
        )
        XCTAssertEqual(kept, same)
        XCTAssertTrue(fm.fileExists(atPath: same))
    }

    @MainActor
    func testKleinExpandPayloadRemapsPlacementWhenOutputDimsAlign() throws {
        guard let plugin = ImageGenPluginCatalog.plugin(pluginID: "flux_klein_9b_kv_expand") else {
            XCTFail("missing expand plugin")
            return
        }
        let config = ProwserTestSupport.ephemeralAppConfig()
        let values: [String: Any] = [
            "width": 1030,
            "height": 770,
            "placement_x": 100,
            "placement_y": 50,
            "placement_w": 830,
            "placement_h": 670,
            "prompt": "extend sky",
            "steps": 4,
            "random_seed": true,
            "source_image_path": "/tmp/unused-source.png",
        ]
        let payload = try ImageGenWorkerPayloadBuilder.build(
            plugin: plugin,
            values: values,
            outputPath: "/tmp/out.webp",
            config: config,
            applyImageExit: false
        )
        let alignedW = payload["width"] as? Int ?? 0
        let alignedH = payload["height"] as? Int ?? 0
        XCTAssertEqual(alignedW % 16, 0)
        XCTAssertEqual(alignedH % 16, 0)
        XCTAssertLessThanOrEqual(alignedW, 1030)
        XCTAssertLessThanOrEqual(alignedH, 770)
        let prompt = payload["prompt"] as? String ?? ""
        XCTAssertTrue(
            prompt.hasPrefix("Extend the provided image to fill the unused space in the image."),
            "klein expand prompt prefix missing: \(prompt)"
        )
        XCTAssertTrue(prompt.lowercased().contains("extend sky"), "user prompt not appended: \(prompt)")
        guard alignedW != 1030 || alignedH != 770 else {
            XCTFail("expected snap from 1030×770")
            return
        }
        let px = payload["placement_x"] as? Int ?? -1
        let py = payload["placement_y"] as? Int ?? -1
        let pw = payload["placement_w"] as? Int ?? -1
        let ph = payload["placement_h"] as? Int ?? -1
        XCTAssertNotEqual(px, 100)
        XCTAssertGreaterThanOrEqual(px, 0)
        XCTAssertLessThanOrEqual(px + pw, alignedW)
        XCTAssertLessThanOrEqual(py + ph, alignedH)
        XCTAssertGreaterThanOrEqual(pw, ExpandPlacementMath.minPlacementEdge)
        XCTAssertGreaterThanOrEqual(ph, ExpandPlacementMath.minPlacementEdge)
    }

    @MainActor
    func testExpandMaskMatchesPythonKeepAndGenerateRegions() throws {
        let source = solidImage(width: 160, height: 120, red: 255, green: 0, blue: 0)
        let (background, mask) = ImageGenOutpaintMask.prepareImageAndMaskAtRect(
            source: source,
            canvasW: 320,
            canvasH: 240,
            x: 40,
            y: 30,
            w: 160,
            h: 120,
            overlapPercentage: 2
        )
        let bgCenter = rgb(background, x: 120, yTop: 90)
        XCTAssertGreaterThan(bgCenter.0, 200, "background center \(bgCenter)")
        XCTAssertLessThan(bgCenter.1, 80, "background center \(bgCenter)")
        XCTAssertLessThan(bgCenter.2, 80, "background center \(bgCenter)")

        let maskBorder = maskLuma(mask, x: 0, yTop: 0)
        let maskCenter = maskLuma(mask, x: 120, yTop: 90)
        XCTAssertEqual(maskBorder, 255, "generate region must be white, got \(maskBorder)")
        XCTAssertEqual(maskCenter, 0, "keep region must be black, got \(maskCenter)")

        let composite = ImageGenOutpaintMask.compositeMaskedRegionsForKleinEdit(
            background: background,
            mask: mask
        )

        // Outside the placement: composite uses neutral gray for the generate region.
        let border = rgb(composite, x: 0, yTop: 0)
        XCTAssertEqual(border.0, 128, "composite border R \(border)")
        XCTAssertEqual(border.1, 128, "composite border G \(border)")
        XCTAssertEqual(border.2, 128, "composite border B \(border)")

        // Inside the keep rect (inset by overlap): original photo, not gray.
        let center = rgb(composite, x: 120, yTop: 90)
        XCTAssertGreaterThan(center.0, 200, "composite center \(center)")
        XCTAssertLessThan(center.1, 80, "composite center \(center)")
        XCTAssertLessThan(center.2, 80, "composite center \(center)")
    }

    @MainActor
    func testResizeImagePublicPreservesVerticalOrientation() throws {
        let source = halfRedTopHalfBlueBottomImage(width: 100, height: 100)
        let topBefore = rgb(source, x: 50, yTop: 10)
        let bottomBefore = rgb(source, x: 50, yTop: 90)
        XCTAssertFalse(
            topBefore.0 == bottomBefore.0 && topBefore.1 == bottomBefore.1 && topBefore.2 == bottomBefore.2,
            "fixture must differ vertically \(topBefore) vs \(bottomBefore)"
        )
        let resized = ImageGenOutpaintMask.resizeImagePublic(source, width: 50, height: 50)
        let topAfter = rgb(resized, x: 25, yTop: 5)
        let bottomAfter = rgb(resized, x: 25, yTop: 45)
        XCTAssertEqual(topAfter.0, topBefore.0, accuracy: 8, "resize should preserve top R \(topBefore) → \(topAfter)")
        XCTAssertEqual(topAfter.2, topBefore.2, accuracy: 8, "resize should preserve top B")
        XCTAssertEqual(bottomAfter.0, bottomBefore.0, accuracy: 8, "resize should preserve bottom R")
        XCTAssertEqual(bottomAfter.2, bottomBefore.2, accuracy: 8, "resize should preserve bottom B")
    }

    @MainActor
    func testExpandCompositePreservesVerticalOrientationThroughPNG() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("klein-expand-orient-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let pngPath = dir.appendingPathComponent("half.png").path
        let raw = halfRedTopHalfBlueBottomImage(width: 100, height: 100)
        XCTAssertTrue(ImageGenOutpaintMask.savePNG(raw, path: pngPath))
        guard let oriented = ImageDisplayLoader.orientedCGImage(for: pngPath) else {
            XCTFail("could not load half PNG via ImageDisplayLoader")
            return
        }
        let (background, mask) = ImageGenOutpaintMask.prepareImageAndMaskAtRect(
            source: oriented,
            canvasW: 200,
            canvasH: 200,
            x: 50,
            y: 50,
            w: 100,
            h: 100,
            overlapPercentage: 2
        )
        let bgTop = rgb(background, x: 100, yTop: 55)
        let bgBottom = rgb(background, x: 100, yTop: 145)
        XCTAssertFalse(bgTop.0 == bgBottom.0 && bgTop.1 == bgBottom.1 && bgTop.2 == bgBottom.2,
                       "placement should preserve distinct vertical samples")

        let composite = ImageGenOutpaintMask.compositeMaskedRegionsForKleinEdit(
            background: background,
            mask: mask
        )
        let beforeSaveTop = rgb(composite, x: 100, yTop: 55)
        XCTAssertEqual(beforeSaveTop.0, bgTop.0, "composite top R")
        XCTAssertEqual(beforeSaveTop.2, bgTop.2, "composite top B")

        let compositePath = dir.appendingPathComponent("composite.png").path
        XCTAssertTrue(ImageGenOutpaintMask.savePNG(composite, path: compositePath))
        guard let reloaded = ImageGenOutpaintMask.loadRasterCGImage(path: compositePath) else {
            XCTFail("could not reload composite PNG")
            return
        }
        let topInside = rgb(reloaded, x: 100, yTop: 55)
        let bottomInside = rgb(reloaded, x: 100, yTop: 145)
        XCTAssertEqual(topInside.0, bgTop.0, accuracy: 4, "PNG top R")
        XCTAssertEqual(topInside.2, bgTop.2, accuracy: 4, "PNG top B")
        XCTAssertEqual(bottomInside.0, bgBottom.0, accuracy: 4, "PNG bottom R")
        XCTAssertEqual(bottomInside.2, bgBottom.2, accuracy: 4, "PNG bottom B")
    }

    @MainActor
    func testExpandPrepPreservesAspectRatioInsidePlacementBox() throws {
        let wide = solidImage(width: 400, height: 200, red: 255, green: 0, blue: 0)
        let (background, mask) = ImageGenOutpaintMask.prepareImageAndMaskAtRect(
            source: wide,
            canvasW: 736,
            canvasH: 448,
            x: 0,
            y: 0,
            w: 736,
            h: 448,
            overlapPercentage: 2
        )
        _ = mask
        let leftCorner = rgb(background, x: 4, yTop: 4)
        XCTAssertGreaterThan(leftCorner.0, 250, "white margin expected, got \(leftCorner)")
        let composite = ImageGenOutpaintMask.compositeMaskedRegionsForKleinEdit(
            background: background,
            mask: mask
        )
        let border = rgb(composite, x: 4, yTop: 4)
        XCTAssertGreaterThan(border.0, 100, "gray margin R \(border)")
        XCTAssertGreaterThan(border.1, 100, "gray margin G \(border)")
        XCTAssertGreaterThan(border.2, 100, "gray margin B \(border)")
    }

    @MainActor
    func testExpandPrepPreservesImageDisplayLoaderOrientation() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("klein-expand-loader-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let pngPath = dir.appendingPathComponent("source.png").path
        let source = halfRedTopHalfBlueBottomImage(width: 100, height: 100)
        XCTAssertTrue(ImageGenOutpaintMask.savePNG(source, path: pngPath))
        guard let oriented = ImageDisplayLoader.orientedCGImage(for: pngPath) else {
            XCTFail("ImageDisplayLoader could not load PNG")
            return
        }
        let sampleY = 12
        let loaderSample = rgb(oriented, x: 50, yTop: sampleY)

        let px = 50
        let py = 50
        let (background, mask) = ImageGenOutpaintMask.prepareImageAndMaskAtRect(
            source: oriented,
            canvasW: 200,
            canvasH: 200,
            x: px,
            y: py,
            w: 100,
            h: 100,
            overlapPercentage: 2
        )
        _ = mask
        let prepSample = rgb(background, x: px + 50, yTop: py + sampleY)
        XCTAssertEqual(loaderSample.0, prepSample.0, accuracy: 4, "R \(loaderSample) vs \(prepSample)")
        XCTAssertEqual(loaderSample.1, prepSample.1, accuracy: 4, "G")
        XCTAssertEqual(loaderSample.2, prepSample.2, accuracy: 4, "B")
    }

    private func halfRedTopHalfBlueBottomImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return solidImage(width: width, height: height, red: 255, green: 0, blue: 0)
        }
        let half = height / 2
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: CGFloat(half), width: CGFloat(width), height: CGFloat(height - half)))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(half)))
        return ctx.makeImage() ?? solidImage(width: width, height: height, red: 255, green: 0, blue: 0)
    }

    private func solidImage(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(
            red: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: 1
        ))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Device Gray mask sample (top-left coords); RGB ``rgb`` cannot represent L-mode masks.
    private func maskLuma(_ image: CGImage, x: Int, yTop: Int) -> UInt8 {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels[yTop * width + x]
    }

    private func rgb(_ image: CGImage, x: Int, yTop: Int) -> (UInt8, UInt8, UInt8) {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let index = (yTop * width + x) * 4
        return (pixels[index], pixels[index + 1], pixels[index + 2])
    }

    private func createSolidPNG(at path: String, width: Int, height: Int) -> Bool {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            return false
        }
        guard let destination = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    private func assertPayloadSubset(
        _ payload: [String: Any],
        matches golden: [String: Any],
        ignoring: Set<String>
    ) {
        for (key, expected) in golden {
            if ignoring.contains(key) { continue }
            guard let actual = payload[key] else {
                XCTFail("missing key \(key)")
                continue
            }
            if let e = expected as? Int, let a = actual as? Int {
                XCTAssertEqual(a, e, key)
            } else if let e = expected as? Bool, let a = actual as? Bool {
                XCTAssertEqual(a, e, key)
            } else if let e = expected as? String, let a = actual as? String {
                XCTAssertEqual(a, e, key)
            } else {
                XCTAssertEqual("\(actual)", "\(expected)", key)
            }
        }
    }
}
