import Foundation

/// Debug counters for thumbnail grid performance (layout, draw, loads).
enum ThumbnailGridPerfDiagnostics {
    #if DEBUG
    private(set) static var lastLayoutDurationMs: Double = 0
    private(set) static var lastDrawDurationMs: Double = 0
    private(set) static var lastIntersectionScanCount: Int = 0
    private(set) static var lastThumbnailLoadRequests: Int = 0
    private(set) static var lastMeasureAdvanceCalls: Int = 0

    static func recordLayout(durationMs: Double) {
        lastLayoutDurationMs = durationMs
    }

    static func recordDraw(durationMs: Double) {
        lastDrawDurationMs = durationMs
    }

    static func recordIntersectionScan(count: Int) {
        lastIntersectionScanCount = count
    }

    static func recordThumbnailLoadRequests(count: Int) {
        lastThumbnailLoadRequests = count
    }

    static func resetMeasureAdvanceCalls() {
        lastMeasureAdvanceCalls = 0
    }

    static func incrementMeasureAdvanceCalls(_ delta: Int = 1) {
        lastMeasureAdvanceCalls += delta
    }
    #else
    static func recordLayout(durationMs: Double) {}
    static func recordDraw(durationMs: Double) {}
    static func recordIntersectionScan(count: Int) {}
    static func recordThumbnailLoadRequests(count: Int) {}
    static func resetMeasureAdvanceCalls() {}
    static func incrementMeasureAdvanceCalls(_ delta: Int = 1) {}
    #endif
}
