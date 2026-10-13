import XCTest
@testable import Prowser

final class LoRAJobSnapshotRetainTests: XCTestCase {
    func testStackModeFiltersToValidIDsAndClearsResolvedPaths() {
        var values: [String: Any] = [
            "mflux_lora_stack": ["keep_me", "drop_me"],
            "mflux_lora_paths": ["/tmp/a.safetensors"],
            "mflux_lora_scales_by_id": ["keep_me": 1.0, "drop_me": 0.5],
        ]

        let changed = LoRAJobSnapshot.retainApplicableLoras(
            in: &values,
            validIDs: ["keep_me"],
            stackMode: true
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(values["mflux_lora_stack"] as? [String], ["keep_me"])
        XCTAssertNil(values["mflux_lora"])
        XCTAssertNil(values["mflux_lora_paths"])
        XCTAssertEqual(
            values["mflux_lora_scales_by_id"] as? [String: Double],
            ["keep_me": 1.0]
        )
    }

    func testSingleModeKeepsFirstValidAndRemovesStackKey() {
        var values: [String: Any] = [
            "mflux_lora_stack": ["only_one"],
            "mflux_lora": "legacy_should_clear",
        ]

        let changed = LoRAJobSnapshot.retainApplicableLoras(
            in: &values,
            validIDs: ["only_one"],
            stackMode: false
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(values["mflux_lora"] as? String, "only_one")
        XCTAssertNil(values["mflux_lora_stack"])
    }

    func testNoOpWhenSelectionAndShapeAlreadyMatch() {
        var values: [String: Any] = [
            "mflux_lora_stack": ["a"],
            "mflux_lora_scales_by_id": ["a": 1.0],
        ]

        let changed = LoRAJobSnapshot.retainApplicableLoras(
            in: &values,
            validIDs: ["a"],
            stackMode: true
        )

        XCTAssertFalse(changed)
    }

    func testPreservesSelectionWhenRetainingAllCurrentIDs() {
        var values: [String: Any] = [
            "mflux_lora_stack": ["a", "b"],
            "mflux_lora_paths": ["/p"],
            LoRAJobSnapshot.loraTriggerWordsKey: ["tok"],
        ]

        let changed = LoRAJobSnapshot.retainApplicableLoras(
            in: &values,
            validIDs: ["a", "b"],
            stackMode: true
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(values["mflux_lora_stack"] as? [String], ["a", "b"])
        XCTAssertNil(values["mflux_lora_paths"])
        XCTAssertNil(values[LoRAJobSnapshot.loraTriggerWordsKey])
    }

    func testNoLoraHostClearsSelection() {
        var values: [String: Any] = [
            "mflux_lora": "some_lora",
            "mflux_lora_scales_by_id": ["some_lora": 0.8],
        ]

        let changed = LoRAJobSnapshot.retainApplicableLoras(
            in: &values,
            validIDs: [],
            stackMode: false
        )

        XCTAssertTrue(changed)
        XCTAssertNil(values["mflux_lora"])
        XCTAssertNil(values["mflux_lora_scales_by_id"])
    }
}
