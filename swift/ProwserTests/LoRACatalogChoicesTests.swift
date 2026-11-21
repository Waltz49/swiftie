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

    func testKlein9BKVPluginSharesEnablementAcross9BFamilyNot4B() throws {
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
            Set(LoRAModelRegistry.flux2KleinSharedRunDialogModelKeys())
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
        XCTAssertTrue(
            choices.contains { $0.id == loraID },
            "9B KV run dialog should list LoRAs enabled on the shared Klein 9B settings row"
        )

        let klein4BPlugin = ImageGenPluginDescriptor(
            pluginID: "flux_klein_4b_create",
            pipelineID: "mflux_flux2_klein_create",
            function: "create",
            displayName: "FLUX.2 Klein 4B",
            hfModelID: LoRAHFModelIDs.flux2Klein4B,
            loraHostID: LoRAHostRegistry.flux2Klein
        )
        XCTAssertEqual(
            LoRAModelRegistry.loraCatalogModelKeys(forPlugin: klein4BPlugin),
            [LoRAHFModelIDs.flux2Klein4B]
        )
        var lc4BOnly = lc
        var by4B = (lc4BOnly[LoRACatalogSettings.byModelKey] as? [String: Any]) ?? [:]
        by4B[LoRAHFModelIDs.flux2Klein4B] = [
            "enabled_ids": [loraID],
            LoRACatalogSettings.deletedIDsKey: [],
        ]
        by4B.removeValue(forKey: LoRAHFModelIDs.flux2Klein9B)
        lc4BOnly[LoRACatalogSettings.byModelKey] = by4B
        let choicesOn9BKV = LoRACatalog.choicesForPlugin(plugin: plugin, lc: lc4BOnly)
        XCTAssertFalse(
            choicesOn9BKV.contains { $0.id == loraID },
            "LoRAs enabled only on Klein 4B must not appear on 9B-family run dialogs"
        )
    }

    func testKlein9BKVRunDialogOmitsLoraProbedOnlyOn4BRow() throws {
        let plugin = ImageGenPluginDescriptor(
            pluginID: "flux_klein_9b_kv_create",
            pipelineID: "mflux_flux2_klein_create",
            function: "create",
            displayName: "FLUX.2 Klein 9B KV",
            hfModelID: LoRAHFModelIDs.flux2Klein9BKV,
            loraHostID: LoRAHostRegistry.flux2Klein
        )

        let loraID = "user_klein_4b_probe_only"
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
                    "display_name": "4B probe only",
                    "repo_id": "",
                    "filename": "",
                    "scale": 1,
                    "best_guess": 1,
                    "local_path": weightsURL.path,
                    "base_hf_model_id": LoRAHFModelIDs.flux2Klein4B,
                    "min_steps": 2,
                ],
            ],
            LoRACatalogSettings.byModelKey: [
                LoRAHFModelIDs.flux2Klein9BKV: [
                    "enabled_ids": [loraID],
                    LoRACatalogSettings.deletedIDsKey: [],
                ],
            ],
            "model_support": [loraID: [LoRAHFModelIDs.flux2Klein4B]],
        ]

        let choices = LoRACatalog.choicesForPlugin(plugin: plugin, lc: lc)
        XCTAssertFalse(choices.contains { $0.id == loraID })
    }
}