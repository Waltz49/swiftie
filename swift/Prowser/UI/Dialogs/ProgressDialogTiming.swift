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
