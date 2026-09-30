import Foundation

/// Shared progress-dialog refresh rules (1 Hz UI, 5 s before showing time remaining).
enum ProgressDialogTiming {
    static let progressUpdateInterval: TimeInterval = 1.0
    static let estimateWarmupInterval: TimeInterval = 5.0
    static let estimateRefreshInterval: TimeInterval = 1.0

    static func formatRemainingDuration(_ seconds: TimeInterval) -> String {
        let total = max(1, Int(seconds.rounded()))
        if total < 60 { return "\(total) sec" }
        let minutes = total / 60
        let sec = total % 60
        if minutes < 60 {
            return sec > 0 ? "\(minutes) min \(sec) sec" : "\(minutes) min"
        }
        let hours = minutes / 60
        let remMin = minutes % 60
        return remMin > 0 ? "\(hours) hr \(remMin) min" : "\(hours) hr"
    }
}

/// Coalesces high-frequency download byte callbacks before they schedule main-thread panel updates.
final class ProgressByteReportThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEmitUptime: UInt64 = 0

    func shouldEmit(written: Int64, expected: Int64) -> Bool {
        if written == 0 { return true }
        lock.lock()
        defer { lock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        let minIntervalNs = UInt64(ProgressDialogTiming.progressUpdateInterval * 1_000_000_000)
        if expected > 0, written < expected, now - lastEmitUptime < minIntervalNs {
            return false
        }
        lastEmitUptime = now
        return true
    }
}
