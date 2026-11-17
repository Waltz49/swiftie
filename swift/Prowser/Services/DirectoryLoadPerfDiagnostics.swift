import Foundation

/// Debug timings for directory scan/sort (macro performance baseline).
enum DirectoryLoadPerfDiagnostics {
    #if DEBUG
    private(set) static var lastScanDurationMs: Double = 0
    private(set) static var lastSortDurationMs: Double = 0
    private(set) static var lastSortedPathCount: Int = 0
    private(set) static var lastSortMode: String = ""

    static func recordScan(durationMs: Double, pathCount: Int) {
        lastScanDurationMs = durationMs
        _ = pathCount
    }

    static func recordSort(durationMs: Double, pathCount: Int, sortMode: String) {
        lastSortDurationMs = durationMs
        lastSortedPathCount = pathCount
        lastSortMode = sortMode
    }

    static func resetForTesting() {
        lastScanDurationMs = 0
        lastSortDurationMs = 0
        lastSortedPathCount = 0
        lastSortMode = ""
    }
    #else
    static func recordScan(durationMs: Double, pathCount: Int) {}
    static func recordSort(durationMs: Double, pathCount: Int, sortMode: String) {}
    static func resetForTesting() {}
    #endif
}