import XCTest
@testable import Prowser

final class ThumbnailUniformGridLayoutTests: XCTestCase {
    func testUniformGridOmitsOverlayWork() {
        let paths = (0..<120).map { "/tmp/grid/file_\($0).jpg" }
        let layout = ThumbnailStandardGridLayout.compute(
            paths: paths,
            viewportWidth: 900,
            thumbnailSize: 150,
            showFilename: false,
            showImageSize: false,
            showExtensions: true,
            basenamesNeedingExtensions: []
        )
        XCTAssertTrue(layout.usesUniformRowHeights)
        XCTAssertEqual(layout.overlayHeights.count, 0)
        XCTAssertEqual(layout.itemFrames.count, paths.count)
        XCTAssertFalse(layout.rowVerticalBounds.isEmpty)
        XCTAssertEqual(layout.rowVerticalBounds.count, layout.rowLayout.totalRows)
    }

    func testRowBoundsIntersectionMatchesBruteForceForUniformGrid() {
        let paths = (0..<80).map { "/tmp/grid/photo_\($0).jpg" }
        let layout = ThumbnailStandardGridLayout.compute(
            paths: paths,
            viewportWidth: 800,
            thumbnailSize: 150,
            showFilename: false,
            showImageSize: false,
            showExtensions: true,
            basenamesNeedingExtensions: []
        )
        let query = NSRect(x: 0, y: 200, width: 800, height: 400)
        let rows = rowIndices(for: query, bounds: layout.rowVerticalBounds)
        var fromRows: Set<Int> = []
        for row in rows {
            for index in layout.rowLayout.rowToIndices[row] ?? [] {
                if layout.itemFrames[index]?.intersects(query) == true {
                    fromRows.insert(index)
                }
            }
        }
        let brute = Set((0..<paths.count).filter { layout.itemFrames[$0]?.intersects(query) == true })
        XCTAssertEqual(fromRows, brute)
    }

    private func rowIndices(
        for query: NSRect,
        bounds: [(minY: CGFloat, maxY: CGFloat)]
    ) -> [Int] {
        var result: [Int] = []
        for (row, span) in bounds.enumerated() {
            if span.maxY < query.minY { continue }
            if span.minY > query.maxY { break }
            result.append(row)
        }
        return result
    }
}
