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
    func testExtSortAscendingAndReversed() {
        let png = "/tmp/a.png"
        let jpg = "/tmp/b.jpg"
        let gif = "/tmp/c.gif"
        let paths = [png, jpg, gif]
        let options = SortingService.Options(mode: .ext, reversed: false, useExifDate: false)
        let sorted = SortingService.sorted(paths, options: options, metadataCache: nil)
        XCTAssertEqual(sorted, [gif, jpg, png])

        let reversed = SortingService.Options(mode: .ext, reversed: true, useExifDate: false)
        let reversedSorted = SortingService.sorted(paths, options: reversed, metadataCache: nil)
        XCTAssertEqual(reversedSorted, [png, jpg, gif])
    }

    @MainActor
    func testExtSortUsesNameWithExtensionAsTieBreaker() {
        let zebra = "/tmp/zebra.jpg"
        let apple = "/tmp/apple.jpg"
        let mango = "/dir/mango.jpg"
        let paths = [zebra, apple, mango]
        let options = SortingService.Options(mode: .ext, reversed: false, useExifDate: false)
        let sorted = SortingService.sorted(paths, options: options, metadataCache: nil)
        XCTAssertEqual(sorted, [apple, mango, zebra])

        let reversed = SortingService.Options(mode: .ext, reversed: true, useExifDate: false)
        let reversedSorted = SortingService.sorted(paths, options: reversed, metadataCache: nil)
        XCTAssertEqual(reversedSorted, [apple, mango, zebra])
    }

    @MainActor
    func testCommentsSortUsesNameWithExtensionAsTieBreaker() {
        let zebra = "/tmp/zebra.jpg"
        let apple = "/tmp/apple.jpg"
        let paths = [zebra, apple]
        let ranks = [zebra: 1, apple: 1]
        let options = SortingService.Options(mode: .comments, reversed: false, useExifDate: false)
        let sorted = SortingService.sorted(paths, options: options, metadataCache: nil, commentRanks: ranks)
        XCTAssertEqual(sorted, [apple, zebra])
    }

    @MainActor
    func testRandomSortPreservesCount() {
        let paths = (1...20).map { "/tmp/img\($0).jpg" }
        let options = SortingService.Options(mode: .random, reversed: false, useExifDate: false)
        let sorted = SortingService.sorted(paths, options: options, metadataCache: nil)
        XCTAssertEqual(Set(sorted), Set(paths))
    }

    @MainActor
    func testCommentsSortUsesColumnRanksWithoutReread() {
        let fire = "/tmp/fire.jpg"
        let check = "/tmp/check.jpg"
        let blank = "/tmp/blank.jpg"
        let paths = [blank, check, fire]
        let ranks = [fire: 2, check: 1, blank: 0]
        let options = SortingService.Options(mode: .comments, reversed: false, useExifDate: false)
        let sorted = SortingService.sorted(paths, options: options, metadataCache: nil, commentRanks: ranks)
        XCTAssertEqual(sorted, [fire, check, blank])

        let reversed = SortingService.Options(mode: .comments, reversed: true, useExifDate: false)
        let reversedSorted = SortingService.sorted(paths, options: reversed, metadataCache: nil, commentRanks: ranks)
        XCTAssertEqual(reversedSorted, [blank, check, fire])
    }
}
