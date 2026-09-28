import XCTest
@testable import Prowser

final class ReferenceGraphLayoutOverlayTests: XCTestCase {
    func testLayerUsesMaxOverlayHeightAmongNodes() {
        let shortPath = "/tmp/refs/short.jpg"
        let longPath = "/tmp/refs/very_long_reference_graph_node_basename_for_wrapping.jpg"
        let graph = ReferenceGraph(
            nodes: [shortPath, longPath],
            edges: [(shortPath, longPath)],
            focusPath: shortPath,
            pathOrder: [shortPath, longPath]
        )
        let context = ReferenceGraphOverlayLayoutContext(
            showFilename: true,
            showImageSize: false,
            showExtensions: false,
            basenamesNeedingExtensions: []
        )
        let layout = ReferenceGraphLayout.computeLayout(
            graph: graph,
            viewportWidth: 1200,
            thumbnailSize: 150,
            overlayHeight: 26,
            overlayContext: context,
            fitToViewportWidth: true,
            edgeColorTheme: "dark",
            overlayCache: ThumbnailFilenameOverlayCache()
        )
        guard let shortRect = layout.nodeRects[shortPath],
              let longRect = layout.nodeRects[longPath] else {
            XCTFail("Missing node rects")
            return
        }
        XCTAssertEqual(shortRect.height, longRect.height, accuracy: 0.5)
        XCTAssertGreaterThan(layout.overlayHeightsByPath[longPath] ?? 0, layout.overlayHeightsByPath[shortPath] ?? 0)
        XCTAssertFalse(layout.edgeRoutes.isEmpty)
    }
}
