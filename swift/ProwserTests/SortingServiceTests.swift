import XCTest
@testable import Prowser

final class SortingServiceTests: XCTestCase {
    @MainActor
    func testNameSortAscending() {
        let paths = ["/tmp/b.jpg", "/tmp/a.jpg", "/tmp/c.jpg"]
        let options = SortingService.Options(mode: .name, reversed: false, useExifDate: false)
        let sorted = SortingService.sorted(paths, options: options, metadataCache: nil)
        XCTAssertEqual(sorted.map { ($0 as NSString).lastPathComponent }, ["a.jpg", "b.jpg", "c.jpg"])
    }

    @MainActor
    func testNameSortReversed() {
        let paths = ["/tmp/b.jpg", "/tmp/a.jpg"]
        let options = SortingService.Options(mode: .name, reversed: true, useExifDate: false)
        let sorted = SortingService.sorted(paths, options: options, metadataCache: nil)
        XCTAssertEqual(sorted.map { ($0 as NSString).lastPathComponent }, ["b.jpg", "a.jpg"])
    }

    @MainActor
    func testRandomSortPreservesCount() {
        let paths = (1...20).map { "/tmp/img\($0).jpg" }
        let options = SortingService.Options(mode: .random, reversed: false, useExifDate: false)
        let sorted = SortingService.sorted(paths, options: options, metadataCache: nil)
        XCTAssertEqual(Set(sorted), Set(paths))
    }
}
