import CoreGraphics
import XCTest
@testable import Prowser

final class BrowseWallpaperGeometryTests: XCTestCase {
    func testFullImageVisibleWhenScaledToFit() {
        let rect = BrowseWallpaperGeometry.visibleSourceRect(
            viewportWidth: 800,
            viewportHeight: 600,
            sourceWidth: 400,
            sourceHeight: 300,
            scaleFactor: 1.5,
            scrollX: 0,
            scrollY: 0
        )
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 400, height: 300))
    }

    func testPannedVisibleRegionUsesSourcePixels() {
        // View 400×300, layout 1000×800 @2×, scroll (-600, 0) → draw minX -200 (matches imageDrawRect math).
        let viewW: CGFloat = 400
        let viewH: CGFloat = 300
        let layoutW: CGFloat = 1000
        let layoutH: CGFloat = 800
        let scale: CGFloat = 2
        let scrollX: CGFloat = -600
        let scrollY: CGFloat = 0
        let drawW = layoutW * scale
        let drawH = layoutH * scale
        let draw = CGRect(
            x: (viewW - drawW) / 2 - scrollX,
            y: (viewH - drawH) / 2 - scrollY,
            width: drawW,
            height: drawH
        )
        let rect = BrowseWallpaperGeometry.visibleSourceRectFromImageDrawRect(
            viewportWidth: viewW,
            viewportHeight: viewH,
            imageDrawRect: draw,
            scaleFactor: scale,
            sourceWidth: layoutW,
            sourceHeight: layoutH
        )
        let scrollRect = BrowseWallpaperGeometry.visibleSourceRect(
            viewportWidth: viewW,
            viewportHeight: viewH,
            sourceWidth: layoutW,
            sourceHeight: layoutH,
            scaleFactor: scale,
            scrollX: scrollX,
            scrollY: scrollY
        )
        XCTAssertNotNil(rect)
        XCTAssertEqual(rect, scrollRect)
        XCTAssertEqual(rect?.origin.x ?? 0, 100, accuracy: 0.5)
        XCTAssertEqual(rect?.width ?? 0, 200, accuracy: 0.5)
        XCTAssertEqual(rect?.origin.y ?? 0, 325, accuracy: 0.5)
        XCTAssertEqual(rect?.height ?? 0, 150, accuracy: 0.5)
    }

    func testReturnsNilForTinyViewport() {
        let rect = BrowseWallpaperGeometry.visibleSourceRect(
            viewportWidth: 1,
            viewportHeight: 100,
            sourceWidth: 500,
            sourceHeight: 500,
            scaleFactor: 1,
            scrollX: 0,
            scrollY: 0
        )
        XCTAssertNil(rect)
    }

    func testViewportAspectMatchTolerance() {
        XCTAssertTrue(BrowseWallpaperGeometry.viewportAspectMatchesScreen(
            viewportWidth: 1920,
            viewportHeight: 1080,
            screenWidth: 2560,
            screenHeight: 1440
        ))
    }

    func testIntersectionRectWhenImageLetterboxedInViewport() {
        // 16:9 viewport, image drawn 960x540 centered (pillarboxed).
        let draw = CGRect(x: 160, y: 30, width: 960, height: 540)
        let rect = BrowseWallpaperGeometry.visibleSourceRectFromImageDrawRect(
            viewportWidth: 1280,
            viewportHeight: 720,
            imageDrawRect: draw,
            scaleFactor: 0.24,
            sourceWidth: 4000,
            sourceHeight: 2250
        )
        XCTAssertNotNil(rect)
        XCTAssertEqual(rect?.width ?? 0, 960 / 0.24, accuracy: 0.5)
        XCTAssertEqual(rect?.height ?? 0, 540 / 0.24, accuracy: 0.5)
    }
}