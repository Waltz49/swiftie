import XCTest
@testable import Prowser

final class LoRAKleinProbeFamilyTests: XCTestCase {
    func testProbePassOnSceneWorksAllowsEnableOn9BKV() {
        let entry = LoRAEntry(
            hostID: LoRAHostRegistry.flux2Klein,
            loraID: "user_f2k_arms_over_head_v2e10",
            displayName: "F2K_Arms Over Head_V2E10",
            repoID: "",
            filename: "",
            scale: 1,
            bestGuess: 1,
            localPath: nil,
            baseHFModelID: LoRAHFModelIDs.flux2Klein9BKV,
            minSteps: 2,
            mfluxCompatible: nil,
            triggerWord: nil,
            comment: nil,
            referencePrompt: nil,
            sourcePath: nil,
            safetensorsOrigin: nil,
            webPageURL: nil
        )
        let support: [String: [String]] = [
            entry.loraID: [LoRAHFModelIDs.sceneworksFlux2Klein9BKVMLX],
        ]
        XCTAssertTrue(
            LoRAModelRegistry.probeSupportedOnModel(
                entry: entry,
                modelKey: LoRAHFModelIDs.flux2Klein9BKV,
                modelSupport: support
            )
        )
        XCTAssertEqual(
            LoRACatalog.probeStateForModel(
                entry: entry,
                modelKey: LoRAHFModelIDs.flux2Klein9BKV,
                lc: ["model_support": support]
            ),
            "pass"
        )
    }

    func test9BFamilyProbePassDoesNotApplyOn4BSettingsRow() {
        let entry = LoRAEntry(
            hostID: LoRAHostRegistry.flux2Klein,
            loraID: "user_klein_9b_only",
            displayName: "9B only",
            repoID: "",
            filename: "",
            scale: 1,
            bestGuess: 1,
            localPath: nil,
            baseHFModelID: LoRAHFModelIDs.flux2Klein9B,
            minSteps: 2,
            mfluxCompatible: nil,
            triggerWord: nil,
            comment: nil,
            referencePrompt: nil,
            sourcePath: nil,
            safetensorsOrigin: nil,
            webPageURL: nil
        )
        let support: [String: [String]] = [
            entry.loraID: [LoRAHFModelIDs.flux2Klein9BKV],
        ]
        XCTAssertFalse(
            LoRAModelRegistry.probeSupportedOnModel(
                entry: entry,
                modelKey: LoRAHFModelIDs.flux2Klein4B,
                modelSupport: support
            )
        )
        XCTAssertEqual(
            LoRACatalog.probeStateForModel(
                entry: entry,
                modelKey: LoRAHFModelIDs.flux2Klein4B,
                lc: ["model_support": support]
            ),
            "fail",
            "Recorded 9B-family pass must not read as works on the Klein 4B settings row"
        )
    }
}