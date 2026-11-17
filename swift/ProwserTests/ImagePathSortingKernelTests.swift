import XCTest
@testable import Prowser

final class ImagePathSortingKernelTests: XCTestCase {
    func testMergeSortedPreservesOrderForNames() {
        let options = ImagePathSortingKernel.Options(mode: .name, reversed: false, useExifDate: false)
        let existing = ["/tmp/b.png", "/tmp/d.png"]
        let added = ["/tmp/a.png", "/tmp/c.png"]
        let merged = ImagePathSortingKernel.mergeSorted(
            existing: existing,
            newPaths: added,
            options: options,
            metadata: nil
        )
        XCTAssertEqual(
            merged.map { ($0 as NSString).lastPathComponent },
            ["a.png", "b.png", "c.png", "d.png"]
        )
    }

    func testBackgroundCommentRanksMatchClassify() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommentSort-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let blank = dir.appendingPathComponent("blank.jpg").path
        try Data([0xFF, 0xD8, 0xFF]).write(to: URL(fileURLWithPath: blank))
        let ranks = ImagePathSortingKernel.backgroundCommentRanks(for: [blank])
        XCTAssertEqual(ranks[blank], 0)

        let snapshot = DirectoryLoadBackgroundWork.Snapshot(
            path: dir.path,
            extensions: ["jpg"],
            filterPattern: "*",
            sortModeRaw: SortMode.comments.rawValue,
            sortReversed: false,
            useExifDate: false,
            metadataCacheFilePath: "/nonexistent/metadata_cache.json"
        )
        let sorted = DirectoryLoadBackgroundWork.sort([blank], snapshot: snapshot)
        XCTAssertEqual(sorted.paths, [blank])
    }
}