import XCTest
@testable import Prowser

final class ThumbnailSectionedLayoutTests: XCTestCase {
    func testVerticalNavigationUsesVisualRowsNotFlatGrid() {
        let paths = (0..<7).map { "/tmp/group/\($0).jpg" }
        let sections = [
            DuplicateGroupPresentation.DuplicateSection(startIndex: 0, groupKey: "a"),
            DuplicateGroupPresentation.DuplicateSection(startIndex: 4, groupKey: "b"),
        ]
        let layout = ThumbnailSectionedLayout.computeDuplicateLayout(
            paths: paths,
            sections: sections,
            viewportWidth: 1200,
            thumbnailSize: 120,
            showFilename: false,
            showImageSize: false,
            currentImagePath: nil
        )
        XCTAssertGreaterThanOrEqual(layout.columns, 2)
        let rows = layout.rowLayout
        XCTAssertEqual(rows.verticalTarget(currentIndex: 6, stepSign: -1), 2)
        XCTAssertEqual(rows.verticalTarget(currentIndex: 2, stepSign: 1), 6)
        XCTAssertEqual(rows.verticalTarget(currentIndex: 0, stepSign: -1), 0)
    }

    func testRowLayoutUpdatesWhenViewportChangesColumnCount() {
        let paths = (0..<12).map { "/tmp/wide/\($0).jpg" }
        let sections = [
            DuplicateGroupPresentation.DuplicateSection(startIndex: 0, groupKey: "only"),
        ]
        let narrow = ThumbnailSectionedLayout.computeDuplicateLayout(
            paths: paths,
            sections: sections,
            viewportWidth: 400,
            thumbnailSize: 120,
            showFilename: false,
            showImageSize: false,
            currentImagePath: nil
        )
        let wide = ThumbnailSectionedLayout.computeDuplicateLayout(
            paths: paths,
            sections: sections,
            viewportWidth: 1600,
            thumbnailSize: 120,
            showFilename: false,
            showImageSize: false,
            currentImagePath: nil
        )
        XCTAssertNotEqual(narrow.columns, wide.columns)
        XCTAssertNotEqual(
            narrow.rowLayout.rowToIndices,
            wide.rowLayout.rowToIndices
        )
    }
}
