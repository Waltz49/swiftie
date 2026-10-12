import XCTest
@testable import Prowser

final class ImageGenWorkerPayloadBuilderTests: XCTestCase {
    @MainActor
    func testFluxSchnellPayloadMatchesGolden() async throws {
        let config = AppConfig(dataDirectory: FileManager.default.temporaryDirectory)
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
            subdirectory: "Fixtures/ImageGenPayloadGolden"
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
        let config = AppConfig(dataDirectory: dataDir)
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
        let config = AppConfig(dataDirectory: dir)
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
