import XCTest
@testable import Prowser

final class LoRACatalogDedupeTests: XCTestCase {
    private func writeFixtureWeights(at url: URL, byte: UInt8 = 0x20) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var fileData = Data(repeating: byte, count: 1024)
        fileData[0] = 0x20
        try fileData.write(to: url)
    }

    func testDedupeSettingsRowsBySameWeightsFile() throws {
        let winnerID = "user_book_cover_primary"
        let loserID = "user_vintage_book_cover_4b"
        let dir = LoRACachePaths.userCacheRoot.appendingPathComponent(winnerID, isDirectory: true)
        let weights = dir.appendingPathComponent("cover.safetensors")
        try writeFixtureWeights(at: weights)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sharedPath = weights.path
        let lc: [String: Any] = [
            LoRACatalogSettings.userEntriesKey: [
                winnerID: [
                    "host_id": LoRAHostRegistry.flux2Klein,
                    "lora_id": winnerID,
                    "display_name": "Book Cover",
                    "repo_id": "",
                    "filename": "cover.safetensors",
                    "scale": 1,
                    "best_guess": 1,
                    "local_path": sharedPath,
                    "base_hf_model_id": LoRAHFModelIDs.flux2Klein9BKV,
                    "min_steps": 2,
                ],
                loserID: [
                    "host_id": LoRAHostRegistry.flux2Klein,
                    "lora_id": loserID,
                    "display_name": "Book Cover Alt",
                    "repo_id": "",
                    "filename": "",
                    "scale": 1,
                    "best_guess": 1,
                    "local_path": "/no/such/norod.safetensors",
                    "source_path": sharedPath,
                    "base_hf_model_id": LoRAHFModelIDs.flux2Klein9BKV,
                    "min_steps": 2,
                    "trigger_word": "vintage book",
                ],
            ],
            "model_support": [
                winnerID: [LoRAHFModelIDs.flux2Klein9BKV],
                loserID: [LoRAHFModelIDs.flux2Klein9BKV],
            ],
        ]

        let visible = LoRACatalog.catalogEntriesSorted(lc: lc)
        let rows = LoRACatalogDedupe.dedupeSettingsEntriesByWeights(visible, lc: lc)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].triggerWord, "vintage book")
    }

    func testMigrateMergesDuplicateUserEntriesAndEnabledIDs() throws {
        let winnerID = "user_dedupe_winner"
        let loserID = "user_dedupe_loser_2"
        let dir = LoRACachePaths.userCacheRoot.appendingPathComponent(winnerID, isDirectory: true)
        let weights = dir.appendingPathComponent("w.safetensors")
        try writeFixtureWeights(at: weights)
        defer { try? FileManager.default.removeItem(at: dir) }

        let modelKey = LoRAHFModelIDs.flux2Klein9BKV
        let raw: [String: Any] = [
            LoRACatalogSettings.catalogSchemaKey: LoRACatalogSettings.diskFirstSchema,
            LoRACatalogSettings.userEntriesKey: [
                winnerID: [
                    "host_id": LoRAHostRegistry.flux2Klein,
                    "lora_id": winnerID,
                    "display_name": "Winner",
                    "repo_id": "",
                    "filename": "w.safetensors",
                    "scale": 1,
                    "best_guess": 1,
                    "local_path": weights.path,
                    "base_hf_model_id": modelKey,
                    "min_steps": 2,
                ],
                loserID: [
                    "host_id": LoRAHostRegistry.flux2Klein,
                    "lora_id": loserID,
                    "display_name": "Loser",
                    "repo_id": "",
                    "filename": "",
                    "scale": 1,
                    "best_guess": 1,
                    "local_path": weights.path,
                    "base_hf_model_id": modelKey,
                    "min_steps": 2,
                ],
            ],
            LoRACatalogSettings.byModelKey: [
                modelKey: [
                    "enabled_ids": [loserID],
                    LoRACatalogSettings.deletedIDsKey: [],
                ],
            ],
        ]

        var migrated = LoRACatalogSettings.migrateCatalogIfNeeded(raw).catalog
        XCTAssertTrue(LoRACatalogMaintenance.runDiskMaintenance(in: &migrated))
        let userEntries = migrated[LoRACatalogSettings.userEntriesKey] as? [String: Any]
        XCTAssertNil(userEntries?[loserID])
        XCTAssertNotNil(userEntries?[winnerID])
        let slice = (migrated[LoRACatalogSettings.byModelKey] as? [String: Any])?[modelKey] as? [String: Any]
        XCTAssertEqual(slice?["enabled_ids"] as? [String], [winnerID])
    }
}