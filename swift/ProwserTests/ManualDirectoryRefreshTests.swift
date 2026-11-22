import XCTest
@testable import Prowser

@MainActor
final class ManualDirectoryRefreshTests: XCTestCase {
    func testLightRefreshAllowedWhenListingMatchesDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("manual-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = dir.appendingPathComponent("a.jpg").path
        let b = dir.appendingPathComponent("b.jpg").path
        try Data().write(to: URL(fileURLWithPath: a))
        try Data().write(to: URL(fileURLWithPath: b))

        let listing = [a, b]
        XCTAssertTrue(
            DirectoryRefreshService.manualRefreshCanUseLightPresentation(
                candidateList: listing,
                currentDisplayed: listing,
                diskPaths: listing,
                deletedPlaceholderPaths: []
            )
        )
    }

    func testLightRefreshRejectedWhenDiskHasNewFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("manual-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = dir.appendingPathComponent("a.jpg").path
        let b = dir.appendingPathComponent("b.jpg").path
        let c = dir.appendingPathComponent("c.jpg").path
        try Data().write(to: URL(fileURLWithPath: a))
        try Data().write(to: URL(fileURLWithPath: b))
        try Data().write(to: URL(fileURLWithPath: c))

        let displayed = [a, b]
        let disk = [a, b, c]
        XCTAssertFalse(
            DirectoryRefreshService.manualRefreshCanUseLightPresentation(
                candidateList: displayed,
                currentDisplayed: displayed,
                diskPaths: disk,
                deletedPlaceholderPaths: []
            )
        )
    }

    func testLightRefreshRejectedWhenDisplayedHasMissingFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("manual-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = dir.appendingPathComponent("a.jpg").path
        let missing = dir.appendingPathComponent("gone.jpg").path
        try Data().write(to: URL(fileURLWithPath: a))

        let displayed = [a, missing]
        XCTAssertFalse(
            DirectoryRefreshService.manualRefreshCanUseLightPresentation(
                candidateList: displayed,
                currentDisplayed: displayed,
                diskPaths: [a],
                deletedPlaceholderPaths: []
            )
        )
    }

    func testLightRefreshRejectedWhenOrphanedDeletedPlaceholder() {
        let missing = "/tmp/prowser-does-not-exist-\(UUID().uuidString).jpg"
        XCTAssertFalse(
            DirectoryRefreshService.manualRefreshCanUseLightPresentation(
                candidateList: [],
                currentDisplayed: [],
                diskPaths: [],
                deletedPlaceholderPaths: [missing]
            )
        )
    }
}