import XCTest
@testable import Prowser

final class DuplicateHashServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuplicateHashServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testDuplicateSortResultMatchesLegacySortedPaths() throws {
        let (pathA, pathB, pathC) = try makeDuplicateTriple()
        let paths = [pathC, pathA, pathB]

        let result = DuplicateHashService.duplicateSortResult(filePaths: paths, reversed: false)
        let legacy = DuplicateHashService.duplicateSortedPaths(paths, reversed: false)

        XCTAssertEqual(result.sortedPaths, legacy)
    }

    func testGroupPairsReusesHashGroupsWithoutSecondBuildPass() throws {
        let (pathA, pathB, pathC) = try makeDuplicateTriple()
        let paths = [pathA, pathB, pathC]

        #if DEBUG
        DuplicateHashService.resetBuildHashGroupsInvocationCountForTesting()
        #endif

        let result = DuplicateHashService.duplicateSortResult(filePaths: paths, reversed: false)
        let fromSort = DuplicateHashService.duplicateGroupPairs(from: result.hashGroups)
        let merged = DuplicateHashService.groupPairs(
            forDisplayedPaths: result.sortedPaths,
            hashGroups: result.hashGroups
        )

        XCTAssertEqual(fromSort.map(\.path), merged.map(\.path))
        XCTAssertEqual(fromSort.map(\.hash), merged.map(\.hash))

        #if DEBUG
        XCTAssertEqual(DuplicateHashService.buildHashGroupsInvocationCountForTesting, 1)
        #endif
    }

    func testMergingHashGroupsHashesOnlyMissingPaths() throws {
        let (pathA, pathB, _) = try makeDuplicateTriple()
        let locked = tempDir.appendingPathComponent("unique-locked.bin")
        try Data([0xEE]).write(to: locked)

        let base = DuplicateHashService.duplicateSortResult(
            filePaths: [pathA, pathB],
            reversed: false
        ).hashGroups

        #if DEBUG
        DuplicateHashService.resetBuildHashGroupsInvocationCountForTesting()
        #endif

        let displayed = [locked.path, pathA, pathB]
        #if DEBUG
        let countBeforePairs = DuplicateHashService.buildHashGroupsInvocationCountForTesting
        #endif
        let pairs = DuplicateHashService.groupPairs(forDisplayedPaths: displayed, hashGroups: base)

        #if DEBUG
        XCTAssertEqual(
            DuplicateHashService.buildHashGroupsInvocationCountForTesting,
            countBeforePairs,
            "groupPairs should merge without invoking buildHashGroups"
        )
        #endif

        XCTAssertEqual(pairs.map(\.path), [pathA, pathB].sorted())
    }

    @MainActor
    func testDuplicateSortAndSectionPipelineUsesSingleBuildPass() throws {
        let (pathA, pathB, pathC) = try makeDuplicateTriple()
        let paths = [pathC, pathA, pathB]

        #if DEBUG
        DuplicateHashService.resetBuildHashGroupsInvocationCountForTesting()
        #endif

        let options = SortingService.Options(mode: .duplicates, reversed: false, useExifDate: false)
        let sorted = SortingService.sortedWithDuplicateContext(paths, options: options)
        _ = DuplicateHashService.duplicateSections(
            forDisplayedPaths: sorted.paths,
            sortHashGroups: sorted.duplicateHashGroups
        )

        #if DEBUG
        XCTAssertEqual(DuplicateHashService.buildHashGroupsInvocationCountForTesting, 1)
        #endif
    }

    private func makeDuplicateTriple() throws -> (String, String, String) {
        let payload = Data([0xAB, 0xCD, 0xEF])
        let pathA = tempDir.appendingPathComponent("a.img").path
        let pathB = tempDir.appendingPathComponent("b.img").path
        let pathC = tempDir.appendingPathComponent("c.img").path
        try payload.write(to: URL(fileURLWithPath: pathA))
        try payload.write(to: URL(fileURLWithPath: pathB))
        try payload.write(to: URL(fileURLWithPath: pathC))
        return (pathA, pathB, pathC)
    }

}
