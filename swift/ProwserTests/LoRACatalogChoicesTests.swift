import XCTest
@testable import Prowser

final class LoRACatalogChoicesTests: XCTestCase {
    func testZImage4BitPluginUsesTongyiEnabledAndProbeKeys() {
        let plugin = ImageGenPluginDescriptor(
            pluginID: "z_image_turbo_mflux_4bit",
            pipelineID: "mflux_z_image_turbo",
            function: "create",
            displayName: "Z-Image Turbo (4-bit)",
            hfModelID: LoRAHFModelIDs.zImageTurboMflux4Bit,
            loraHostID: "z_image_turbo"
        )
        XCTAssertEqual(
            LoRAModelRegistry.loraProbeModelKey(forPlugin: plugin),
            LoRAHFModelIDs.zImageTurbo
        )
        XCTAssertEqual(
            Set(LoRAModelRegistry.loraCatalogModelKeys(forPlugin: plugin)),
            Set(LoRAModelRegistry.zImageLoraModelKeys())
        )

        let loraID = "user_test_z"
        let weightsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(loraID).safetensors")
        var fileData = Data(repeating: 0, count: 1024)
        fileData[0] = 0x20
        try? fileData.write(to: weightsURL)

        let lc: [String: Any] = [
            LoRACatalogSettings.userEntriesKey: [
                loraID: [
                    "host_id": "z_image_turbo",
                    "lora_id": loraID,
                    "display_name": "Test",
                    "repo_id": "",
                    "filename": "",
                    "scale": 1,
                    "best_guess": 1,
                    "local_path": weightsURL.path,
                    "base_hf_model_id": LoRAHFModelIDs.zImageTurbo,
                    "min_steps": 2,
                ],
            ],
            LoRACatalogSettings.byModelKey: [
                LoRAHFModelIDs.zImageTurbo: [
                    "enabled_ids": [loraID],
                    LoRACatalogSettings.deletedIDsKey: [],
                ],
            ],
            "model_support": [loraID: [LoRAHFModelIDs.zImageTurbo]],
        ]

        let choices = LoRACatalog.choicesForPlugin(plugin: plugin, lc: lc)
        let ids = Set(choices.map(\.id))
        XCTAssertTrue(ids.contains(loraID), "4-bit create plugin should list LoRAs enabled on Tongyi-MAI/Z-Image-Turbo")
    }

    func testKlein9BKVPluginMergesEnabledFromAllKleinSettingsRows() throws {
        let plugin = ImageGenPluginDescriptor(
            pluginID: "flux_klein_9b_kv_create",
            pipelineID: "mflux_flux2_klein_create",
            function: "create",
            displayName: "FLUX.2 Klein 9B KV",
            hfModelID: LoRAHFModelIDs.flux2Klein9BKV,
            loraHostID: LoRAHostRegistry.flux2Klein
        )
        XCTAssertEqual(
            Set(LoRAModelRegistry.loraCatalogModelKeys(forPlugin: plugin)),
            Set(LoRAModelRegistry.flux2KleinLoraCatalogModelKeys())
        )

        let loraID = "user_klein_kv_test"
        let weightsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(loraID).safetensors")
        var fileData = Data(repeating: 0, count: 1024)
        fileData[0] = 0x20
        try fileData.write(to: weightsURL)

        let lc: [String: Any] = [
            LoRACatalogSettings.userEntriesKey: [
                loraID: [
                    "host_id": LoRAHostRegistry.flux2Klein,
                    "lora_id": loraID,
                    "display_name": "Klein test",
                    "repo_id": "",
                    "filename": "",
                    "scale": 1,
                    "best_guess": 1,
                    "local_path": weightsURL.path,
                    "base_hf_model_id": LoRAHFModelIDs.flux2Klein9BKV,
                    "min_steps": 2,
                ],
            ],
            LoRACatalogSettings.byModelKey: [
                LoRAHFModelIDs.flux2Klein9B: [
                    "enabled_ids": [loraID],
                    LoRACatalogSettings.deletedIDsKey: [],
                ],
            ],
            "model_support": [loraID: [LoRAHFModelIDs.flux2Klein9BKV]],
        ]

        let choices = LoRACatalog.choicesForPlugin(plugin: plugin, lc: lc)
        XCTAssertTrue(choices.contains { $0.id == loraID })
    }
}