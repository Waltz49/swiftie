import XCTest
@testable import Prowser

final class FileDataModelTests: XCTestCase {
    @MainActor
    func testNormalizePathExpandsTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let normalized = FileDataModel.normalizePath("~/")
        XCTAssertNotNil(normalized)
        XCTAssertTrue(normalized?.hasPrefix(home) == true)
    }

    @MainActor
    func testPathIsInDirectory() {
        let dir = "/tmp/prowser-test-dir"
        let file = "/tmp/prowser-test-dir/image.jpg"
        XCTAssertTrue(FileDataModel.pathIsInDirectory(file: file, directory: dir))
        XCTAssertFalse(FileDataModel.pathIsInDirectory(file: "/tmp/other/image.jpg", directory: dir))
    }

    @MainActor
    func testSetDisplayedImagesUpdatesIndexWhenPathMissing() {
        let model = FileDataModel()
        model.setDisplayedImages(["/a/one.jpg", "/a/two.jpg"], notify: false)
        model.setCurrentImagePath("/a/two.jpg")
        model.setDisplayedImages(["/a/one.jpg"], notify: false)
        XCTAssertEqual(model.currentIndex, 0)
        XCTAssertEqual(model.currentImagePath, "/a/one.jpg")
    }
}
