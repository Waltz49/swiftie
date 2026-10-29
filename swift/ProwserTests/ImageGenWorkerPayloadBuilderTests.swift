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
