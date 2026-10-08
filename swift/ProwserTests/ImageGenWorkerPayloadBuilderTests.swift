import XCTest
@testable import Prowser

final class ImageGenWorkerPayloadBuilderTests: XCTestCase {
    @MainActor
    func testFluxSchnellPayloadMatchesGolden() throws {
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
        let snap = ImageGenJobValuesSnapshot.snapshotJobValuesAtSubmit(
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
