import XCTest
@testable import Prowser

final class FileTreePresentationStateTests: XCTestCase {
    func testPruneMissingExpandedPathsDropsAbsentDirectories() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-tree-prune-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let existing = temp.appendingPathComponent("keep", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let missing = temp.appendingPathComponent("gone", isDirectory: true).path

        let input: Set<String> = [
            FileTreePresentationState.standardizedPath(existing.path),
            FileTreePresentationState.standardizedPath(missing),
            FileTreePresentationState.standardizedPath("/definitely/not/on/disk-\(UUID().uuidString)"),
        ]
        let pruned = FileTreePresentationState.pruneMissingExpandedPaths(input)
        XCTAssertEqual(pruned, [FileTreePresentationState.standardizedPath(existing.path)])
    }

    func testExpandedPathsAfterCollapsingRemovesSubtree() {
        let collapsed = "/Volumes/DiskA"
        let input: Set<String> = [
            "/Volumes",
            collapsed,
            "\(collapsed)/Photos",
            "/Users/me",
        ]
        let result = FileTreePresentationState.expandedPaths(afterCollapsing: collapsed, in: input)
        XCTAssertTrue(result.contains("/Volumes"))
        XCTAssertTrue(result.contains("/Users/me"))
        XCTAssertFalse(result.contains(collapsed))
        XCTAssertFalse(result.contains("\(collapsed)/Photos"))
    }
}
