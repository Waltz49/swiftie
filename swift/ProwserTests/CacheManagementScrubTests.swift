import XCTest
@testable import Prowser

@MainActor
final class CacheManagementScrubTests: XCTestCase {
    func testScrubTargetUsesManualCellSizeWhenSet() {
        let config = ProwserTestSupport.ephemeralAppConfig()
        config.updateSetting("manual_thumbnail_size", value: true)
        config.updateSetting("thumbnail_cell_size", value: 200.0)
        XCTAssertEqual(CacheManagementService.scrubTargetThumbnailPixelSize(config: config), 200)
    }

    func testScrubTargetUsesMinimumWhenNotManual() {
        let config = ProwserTestSupport.ephemeralAppConfig()
        config.updateSetting("manual_thumbnail_size", value: false)
        config.updateSetting("thumbnail_cell_size", value: 220.0)
        XCTAssertEqual(
            CacheManagementService.scrubTargetThumbnailPixelSize(config: config),
            ThumbnailGridLayoutService.minThumbnailSize
        )
    }

    func testScrubRemovesWrongSizeAndKeepsTarget() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("scrub-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let keepKey = "abc123"
        let orphanKey = "deadbeef"
        try Data([0xFF, 0xD8, 0xFF]).write(to: root.appendingPathComponent("\(keepKey)_200.jpg"))
        try Data([0xFF, 0xD8, 0xFF]).write(to: root.appendingPathComponent("\(keepKey)_150.jpg"))
        try Data([0xFF, 0xD8, 0xFF]).write(to: root.appendingPathComponent("\(orphanKey)_200.jpg"))

        let imagePath = fm.temporaryDirectory.appendingPathComponent("image-\(UUID().uuidString).jpg").path
        try Data([0]).write(to: URL(fileURLWithPath: imagePath))

        let removed = CacheManagementService.scrubThumbnailCache(
            root,
            cacheKeyForPath: [imagePath: keepKey],
            targetThumbnailPixelSize: 200
        )

        XCTAssertEqual(removed, 2)
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("\(keepKey)_200.jpg").path))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("\(keepKey)_150.jpg").path))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("\(orphanKey)_200.jpg").path))
    }

    func testCacheTotalsSeparatesSearchModelsFromImageRecFeatures() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ir-cache-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let modelsDir = root.appendingPathComponent("models", isDirectory: true)
        try fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        try Data(count: 1000).write(to: modelsDir.appendingPathComponent("big.mlmodelc.zip"))

        let featuresDir = root.appendingPathComponent("cnn_features_test", isDirectory: true)
        try fm.createDirectory(at: featuresDir, withIntermediateDirectories: true)
        try Data(count: 50).write(to: featuresDir.appendingPathComponent("a.fcache"))

        let totals = CacheManagementService.cacheTotals(imageRecognitionRoot: root)

        XCTAssertEqual(totals.searchModels, 1000)
        XCTAssertEqual(totals.imageRecognition, 50)
        XCTAssertEqual(totals.total, 1050)
    }
}
