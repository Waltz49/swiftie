import Foundation

/// Streaming AI prompt refinement progress (Python ``model_task_status_info``).
enum AIRefineProgress {
    static let progressTotal = 100
    private static let charBudget = 800
    private static let refreshPercent = 20

    static func stepFromChars(charsReceived: Int) -> Int {
        let total = progressTotal
        if total <= 1 || charsReceived <= 0 { return 0 }
        let budget = max(total - 1, charBudget)
        return min(total - 1, Int(charsReceived * (total - 1) / budget))
    }

    static func bucket(step: Int) -> Int {
        let total = progressTotal
        if total <= 0 { return 0 }
        let refresh = max(1, refreshPercent)
        let pct = min(100, Int(round(100.0 * Double(max(0, step)) / Double(total))))
        return pct / refresh
    }

    static func displayStep(step: Int) -> Int {
        let total = progressTotal
        if total <= 0 || step <= 0 { return 0 }
        let refresh = max(1, refreshPercent)
        let bucket = bucket(step: step)
        return min(total - 1, bucket * refresh)
    }
}
