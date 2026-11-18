import XCTest
@testable import Prowser

final class LoRACatalogPathRepairTests: XCTestCase {
    func testRepairsStalePathViaUserIDPrefixFolder() throws {
        let loraID = "user_test_armbinder"
        let sibling = "user_test_armbinder_2"
        let root = LoRACachePaths.userCacheRoot
        let siblingDir = root.appendingPathComponent(sibling, isDirectory: true)
        try FileManager.default.createDirectory(at: siblingDir, withIntermediateDirectories: true)
        var fileData = Data(repeating: 0, count: 1024)
        fileData[0] = 0x20
        let weights = siblingDir.appendingPathComponent("weights.safetensors")
        try fileData.write(to: weights)
        defer { try? FileManager.default.removeItem(at: siblingDir) }

        var lc: [String: Any] = [
            LoRACatalogSettings.userEntriesKey: [
                loraID: [
                    "host_id": LoRAHostRegistry.flux2Klein,
                    "lora_id": loraID,
                    "display_name": "Test",
                    "repo_id": "",
                    "filename": "",
                    "scale": 1,
                    "best_guess": 1,
                    "local_path": "/tmp/missing.safetensors",
                    "base_hf_model_id": LoRAHFModelIDs.flux2Klein9BKV,
                    "min_steps": 2,
                ],
            ],
        ]

        let fixes = LoRACatalogPathRepair.repairUserEntryPaths(in: &lc)
        XCTAssertEqual(fixes, 1)
        let dict = (lc[LoRACatalogSettings.userEntriesKey] as? [String: Any])?[loraID] as? [String: Any]
        XCTAssertEqual(dict?["local_path"] as? String, weights.path)
    }

    func testMigratePersistsRepairedLocalPath() throws {
        let loraID = "user_migrate_repair"
        let dir = LoRACachePaths.userCacheRoot.appendingPathComponent(loraID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var fileData = Data(repeating: 0, count: 1024)
        fileData[0] = 0x20
        let weights = dir.appendingPathComponent("a.safetensors")
        try fileData.write(to: weights)
        defer { try? FileManager.default.removeItem(at: dir) }

        let raw: [String: Any] = [
            LoRACatalogSettings.catalogSchemaKey: LoRACatalogSettings.diskFirstSchema,
            LoRACatalogSettings.userEntriesKey: [
                loraID: [
                    "host_id": LoRAHostRegistry.flux2Klein,
                    "lora_id": loraID,
                    "display_name": "X",
                    "repo_id": "",
                    "filename": "",
                    "scale": 1,
                    "best_guess": 1,
                    "local_path": "/no/such/file.safetensors",
                    "base_hf_model_id": LoRAHFModelIDs.flux2Klein9BKV,
                    "min_steps": 2,
                ],
            ],
        ]
        var migrated = LoRACatalogSettings.migrateCatalogIfNeeded(raw).catalog
        XCTAssertTrue(LoRACatalogMaintenance.runDiskMaintenance(in: &migrated))
        let dict = (migrated[LoRACatalogSettings.userEntriesKey] as? [String: Any])?[loraID] as? [String: Any]
        XCTAssertEqual(dict?["local_path"] as? String, weights.path)
    }

    func testPrunesEnabledIDsWithoutWeights() throws {
        let loraID = "user_prune_enable_test"
        var lc: [String: Any] = [
            LoRACatalogSettings.userEntriesKey: [
                loraID: [
                    "host_id": LoRAHostRegistry.flux2Klein,
                    "lora_id": loraID,
                    "display_name": "X",
                    "repo_id": "",
                    "filename": "",
                    "scale": 1,
                    "best_guess": 1,
                    "local_path": "/no/such/file.safetensors",
                    "base_hf_model_id": LoRAHFModelIDs.flux2Klein9BKV,
                    "min_steps": 2,
                ],
            ],
            LoRACatalogSettings.byModelKey: [
                LoRAHFModelIDs.flux2Klein9BKV: [
                    "enabled_ids": [loraID],
                    LoRACatalogSettings.deletedIDsKey: [],
                ],
            ],
        ]
        XCTAssertEqual(LoRACatalogPathRepair.pruneUninstalledEnabledIDs(in: &lc), 1)
        let slice = (lc[LoRACatalogSettings.byModelKey] as? [String: Any])?[LoRAHFModelIDs.flux2Klein9BKV] as? [String: Any]
        XCTAssertEqual(slice?["enabled_ids"] as? [String], [])
    }

    func testPruneKeepsEnabledWhenWeightsFoundViaDiscoverPath() throws {
        let loraID = "user_prune_discover_keep"
        let sibling = "user_prune_discover_keep_v2"
        let root = LoRACachePaths.userCacheRoot
        let siblingDir = root.appendingPathComponent(sibling, isDirectory: true)
        try FileManager.default.createDirectory(at: siblingDir, withIntermediateDirectories: true)
        var fileData = Data(repeating: 0, count: 1024)
        fileData[0] = 0x20
        let weights = siblingDir.appendingPathComponent("weights.safetensors")
        try fileData.write(to: weights)
        defer { try? FileManager.default.removeItem(at: siblingDir) }

        var lc: [String: Any] = [
            LoRACatalogSettings.userEntriesKey: [
                loraID: [
                    "host_id": LoRAHostRegistry.flux2Klein,
                    "lora_id": loraID,
                    "display_name": "X",
                    "repo_id": "",
                    "filename": "",
                    "scale": 1,
                    "best_guess": 1,
                    "local_path": "/no/such/file.safetensors",
                    "base_hf_model_id": LoRAHFModelIDs.flux2Klein9BKV,
                    "min_steps": 2,
                ],
            ],
            LoRACatalogSettings.byModelKey: [
                LoRAHFModelIDs.flux2Klein9BKV: [
                    "enabled_ids": [loraID],
                    LoRACatalogSettings.deletedIDsKey: [],
                ],
            ],
        ]
        XCTAssertEqual(LoRACatalogPathRepair.pruneUninstalledEnabledIDs(in: &lc), 0)
        let slice = (lc[LoRACatalogSettings.byModelKey] as? [String: Any])?[LoRAHFModelIDs.flux2Klein9BKV] as? [String: Any]
        XCTAssertEqual(slice?["enabled_ids"] as? [String], [loraID])
    }
}