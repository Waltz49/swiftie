import XCTest
@testable import Prowser

final class CheckLorasImportOptionsTests: XCTestCase {
    func testSelectedLoraKeysForWeightPaths() {
        let paths = [
            "/Users/me/Downloads/foo.safetensors",
            "~/Downloads/bar.safetensors",
        ]
        let keys = CheckLorasOptions.selectedLoraKeys(forWeightPaths: paths)
        XCTAssertEqual(keys.count, 2)
        XCTAssertTrue(keys.allSatisfy { $0.hasPrefix("path:") })
        let stdFoo = (paths[0] as NSString).standardizingPath
        XCTAssertTrue(keys.contains("path:\(stdFoo)"))
    }
}