import XCTest
@testable import Prowser

final class CheckLorasPreviousReportTests: XCTestCase {
    func testPersistAndLoadRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = ProfilePaths(profilePath: root.path)
        CheckLorasPreviousReport.persist(
            profilePaths: paths,
            body: "line one\nline two",
            cancelledBanner: "partial cancel"
        )
        let loaded = CheckLorasPreviousReport.load(profilePaths: paths)
        XCTAssertEqual(loaded?.body, "line one\nline two")
        XCTAssertEqual(loaded?.cancelledBanner, "partial cancel")
    }

    func testPersistClearsBannerWhenNil() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = ProfilePaths(profilePath: root.path)
        CheckLorasPreviousReport.persist(profilePaths: paths, body: "body", cancelledBanner: "banner")
        CheckLorasPreviousReport.persist(profilePaths: paths, body: "body", cancelledBanner: nil)
        let loaded = CheckLorasPreviousReport.load(profilePaths: paths)
        XCTAssertEqual(loaded?.body, "body")
        XCTAssertNil(loaded?.cancelledBanner)
    }

    func testLoadMissingReturnsNil() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paths = ProfilePaths(profilePath: root.path)
        XCTAssertNil(CheckLorasPreviousReport.load(profilePaths: paths))
    }
}
