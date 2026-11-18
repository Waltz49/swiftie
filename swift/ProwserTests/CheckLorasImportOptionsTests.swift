import XCTest
@testable import Prowser

final class CheckLorasImportOptionsTests: XCTestCase {
    func testOptionsForDownloadsImportScopesPaths() {
        let base = CheckLorasOptions(
            modelScope: CheckLorasOptions.modelScopeAll,
            selectedModelKeys: [],
            loraScope: CheckLorasOptions.loraScopeAll,
            selectedLoraKeys: [],
            registrationMode: CheckLorasOptions.registrationIgnorePrevious,
            probePrompt: CheckLorasOptions.defaultProbePrompt,
            skipUnchanged: true,
            checkCrossFamilies: true,
            removeDownloadsAfterImport: false
        )
        let paths = [
            "/Users/me/Downloads/foo.safetensors",
            "~/Downloads/bar.safetensors",
        ]
        let seeded = CheckLorasOptions.optionsForDownloadsImport(paths: paths, base: base)
        XCTAssertEqual(seeded.loraScope, CheckLorasOptions.loraScopeSelected)
        XCTAssertEqual(seeded.modelScope, CheckLorasOptions.modelScopeAll)
        XCTAssertTrue(seeded.removeDownloadsAfterImport)
        XCTAssertEqual(seeded.selectedLoraKeys.count, 2)
        XCTAssertTrue(seeded.selectedLoraKeys.allSatisfy { $0.hasPrefix("path:") })
        let stdFoo = (paths[0] as NSString).standardizingPath
        XCTAssertTrue(seeded.selectedLoraKeys.contains("path:\(stdFoo)"))
    }
}