import XCTest
@testable import Prowser

final class SettingsPathFilesystemCaseTests: XCTestCase {
    @MainActor
    func testPathWithFilesystemNameCasingLeavesSubstringUnchanged() {
        XCTAssertEqual(
            SettingsPathValidation.pathWithFilesystemNameCasing("My Holiday Album"),
            "My Holiday Album"
        )
    }

    @MainActor
    func testPathWithFilesystemNameCasingMatchesOnDiskComponentNames() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("prowser-fs-case-\(UUID().uuidString)", isDirectory: true)
        let mixedDir = parent.appendingPathComponent("MiXeD_CaSe", isDirectory: true)
        try FileManager.default.createDirectory(at: mixedDir, withIntermediateDirectories: true)

        let typed = parent.path + "/mixed_case/extra"
        let corrected = SettingsPathValidation.pathWithFilesystemNameCasing(typed)
        XCTAssertTrue(corrected.hasPrefix(parent.path + "/MiXeD_CaSe"))
        XCTAssertTrue(corrected.hasSuffix("/extra"))

        try FileManager.default.removeItem(at: parent)
    }
}
