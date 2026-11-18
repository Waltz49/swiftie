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
}