import XCTest
@testable import Prowser

@MainActor
final class ThumbnailExcludeServiceTests: XCTestCase {
    func testPathMatchesExcludeRuleIsCaseInsensitive() {
        let imagePath = "/Volumes/Photos/Vacation/IMG_0001.jpg"
        XCTAssertTrue(ThumbnailExcludeService.pathMatchesExcludeRule(fullPath: imagePath, rule: "vacation"))
        XCTAssertTrue(ThumbnailExcludeService.pathMatchesExcludeRule(fullPath: imagePath, rule: "VACATION"))
        XCTAssertFalse(ThumbnailExcludeService.pathMatchesExcludeRule(fullPath: imagePath, rule: "winter"))
    }

    func testPathMatchesExcludeRuleHonorsSpacesInDirectoryNames() {
        let imagePath = "/Users/me/Pictures/My Holiday Album/photo.jpg"
        XCTAssertTrue(
            ThumbnailExcludeService.pathMatchesExcludeRule(fullPath: imagePath, rule: "My Holiday Album")
        )
        XCTAssertTrue(
            ThumbnailExcludeService.pathMatchesExcludeRule(fullPath: imagePath, rule: "my holiday album")
        )
        XCTAssertFalse(
            ThumbnailExcludeService.pathMatchesExcludeRule(fullPath: imagePath, rule: "MyHoliday Album")
        )
    }

    func testPathMatchesExcludeRuleExpandsTildeInRule() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let imagePath = "\(home)/Downloads/Set A/one.jpg"
        XCTAssertTrue(ThumbnailExcludeService.pathMatchesExcludeRule(fullPath: imagePath, rule: "~/Downloads/Set A"))
    }
}
