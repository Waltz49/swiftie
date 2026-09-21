import XCTest
@testable import Prowser

final class ImageListRowFormattingTests: XCTestCase {
    @MainActor
    func testMinimumCommonParentDirectoryForSharedVolumeRoot() {
        let paths = [
            "/Volumes/MiscFS/foo/snert.jpg",
            "/Volumes/MiscFS/bar/chomp.jpg",
        ]
        XCTAssertEqual(
            ImageListRowFormatting.minimumCommonParentDirectory(for: paths),
            "/Volumes/MiscFS"
        )
    }

    @MainActor
    func testMinimumCommonParentDirectoryNilWhenOnlyRootShared() {
        let paths = ["/tmp/a.jpg", "/blah/b.jpg"]
        XCTAssertNil(ImageListRowFormatting.minimumCommonParentDirectory(for: paths))
    }

    @MainActor
    func testMultiDirectoryListUsesRelativeNamesAndHeader() {
        let paths = [
            "/Volumes/MiscFS/foo/snert.jpg",
            "/Volumes/MiscFS/bar/chomp.jpg",
        ]
        let map = ImageListRowFormatting.buildRowDataMap(paths: paths, metadataCache: nil)
        XCTAssertEqual(map[paths[0]]?.nameText, "foo/snert.jpg")
        XCTAssertEqual(map[paths[1]]?.nameText, "bar/chomp.jpg")
        XCTAssertEqual(
            ImageListRowFormatting.listHeaderDirectoryBannerContent(for: paths),
            ImageListRowFormatting.DirectoryBannerContent(
                kind: .multipleDirectories(commonRoot: "/Volumes/MiscFS")
            )
        )
    }

    @MainActor
    func testSingleDirectoryStillUsesBasenames() {
        let paths = ["/Volumes/MiscFS/foo/a.jpg", "/Volumes/MiscFS/foo/b.jpg"]
        let map = ImageListRowFormatting.buildRowDataMap(paths: paths, metadataCache: nil)
        XCTAssertEqual(map[paths[0]]?.nameText, "a.jpg")
        XCTAssertEqual(map[paths[1]]?.nameText, "b.jpg")
        XCTAssertEqual(
            ImageListRowFormatting.listHeaderDirectoryBannerContent(for: paths),
            ImageListRowFormatting.DirectoryBannerContent(
                kind: .singleDirectory(directory: "/Volumes/MiscFS/foo")
            )
        )
    }
}
