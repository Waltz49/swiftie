import XCTest
@testable import Prowser

final class ThumbnailDiskRemovalTests: XCTestCase {
    func testRemoveUsesIndexWithoutScanningUnrelatedKeys() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumb-removal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let targetKey = "abc123"
        let otherKey = "zzz999"
        try Data([0xFF, 0xD8, 0xFF]).write(to: root.appendingPathComponent("\(targetKey)_256.jpg"))
        try Data([0xFF, 0xD8, 0xFF]).write(to: root.appendingPathComponent("\(targetKey)_512.jpg"))
        try Data([0xFF, 0xD8, 0xFF]).write(to: root.appendingPathComponent("\(otherKey)_256.jpg"))

        let index = [targetKey: [256, 512], otherKey: [256]]
        let removed = ThumbnailDiskRemoval.removeFiles(
            directoryPath: root.path,
            cacheKeys: [targetKey],
            indexSizesByKey: index
        )

        XCTAssertEqual(removed, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(targetKey)_256.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(targetKey)_512.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(otherKey)_256.jpg").path))
    }
}
