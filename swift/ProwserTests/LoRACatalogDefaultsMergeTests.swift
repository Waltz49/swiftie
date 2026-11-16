import XCTest
@testable import Prowser

final class LoRACatalogDefaultsMergeTests: XCTestCase {
    func testAddsNewEntryPreservesExisting() {
        let existing: [String: Any] = [
            LoRACatalogSettings.userEntriesKey: [
                "user_keep": [
                    "host_id": "flux1_t2i",
                    "lora_id": "user_keep",
                    "display_name": "Keep",
                    "local_path": "/tmp/a.safetensors",
                    "base_hf_model_id": "black-forest-labs/FLUX.1-dev",
                    "scale": 1.0,
                    "best_guess": 1.0,
                    "min_steps": 2,
                ],
            ],
            LoRACatalogSettings.byModelKey: [
                "black-forest-labs/FLUX.1-dev": [
                    "enabled_ids": ["user_keep"],
                    LoRACatalogSettings.deletedIDsKey: [],
                ],
            ],
        ]
        let imported: [String: Any] = [
            LoRACatalogSettings.userEntriesKey: [
                "user_keep": [
                    "lora_id": "user_keep",
                    "display_name": "Should Not Replace",
                ],
                "user_new": [
                    "host_id": "flux1_t2i",
                    "lora_id": "user_new",
                    "display_name": "New",
                    "local_path": "/tmp/user_new.safetensors",
                    "base_hf_model_id": "black-forest-labs/FLUX.1-dev",
                    "scale": 0.8,
                    "best_guess": 0.8,
                    "min_steps": 2,
                ],
            ],
            LoRACatalogSettings.byModelKey: [
                "black-forest-labs/FLUX.1-dev": [
                    "enabled_ids": ["user_keep", "user_new"],
                    LoRACatalogSettings.deletedIDsKey: [],
                ],
            ],
        ]

        let (merged, result) = LoRACatalogDefaultsMerge.merge(existing: existing, imported: imported)
        XCTAssertEqual(result.entriesAdded, 1)
        XCTAssertEqual(result.entriesSkippedExisting, 1)

        let users = merged[LoRACatalogSettings.userEntriesKey] as? [String: Any]
        let keep = users?["user_keep"] as? [String: Any]
        XCTAssertEqual(keep?["display_name"] as? String, "Keep")

        let byModel = merged[LoRACatalogSettings.byModelKey] as? [String: Any]
        let slice = byModel?["black-forest-labs/FLUX.1-dev"] as? [String: Any]
        let enabled = slice?["enabled_ids"] as? [String] ?? []
        XCTAssertTrue(enabled.contains("user_keep"))
        XCTAssertTrue(enabled.contains("user_new"))
    }
}