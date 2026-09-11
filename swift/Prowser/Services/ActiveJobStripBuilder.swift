import Foundation

/// Local active-job strip builder (Python ``build_active_job_strip_view`` without IPC).
enum ActiveJobStripBuilder {
    private static let completingSlotText = "Completing..."
    private static let continuousSeriesSlotText = "Continuous"

    static func build(
        elapsedSeconds: Double?,
        estimateSeconds: Double?,
        step: Int,
        stepTotal: Int,
        stepsLabel: String,
        cooldownRemaining: Int,
        completedSeries: Int?,
        totalSeries: Int?,
        totalQueueJobs: Int?
    ) -> ActiveJobStripStatusView {
        if cooldownRemaining > 0 {
            var rows: [ActiveJobStripRowKind] = []
            if let completedSeries, let totalSeries, let row = seriesProgressRow(
                completed: completedSeries,
                total: totalSeries
            ) {
                rows.append(row)
            }
            if let totalQueueJobs, let row = queueJobsCountRow(totalJobs: totalQueueJobs) {
                rows.append(row)
            }
            return ActiveJobStripStatusView(
                rows: rows,
                mode: "cooldown",
                cooldownText: "Cooldown:",
                cooldownCountText: "(\(max(0, cooldownRemaining)))",
                showSkipIcon: true,
                showCancelIcon: true
            )
        }

        let elapsed = elapsedSeconds ?? 0
        let pendingStart = stepTotal > 0 && step <= 0
        var rows: [ActiveJobStripRowKind] = []
        rows.append(timeProgressRow(
            elapsed: elapsed,
            estimate: estimateSeconds,
            showPendingStart: pendingStart
        ))

        if stepTotal > 0 {
            if let row = stepsProgressRow(step: step, total: stepTotal, label: stepsLabel) {
                rows.append(row)
            }
        }

        if let completedSeries, let totalSeries, let row = seriesProgressRow(
            completed: completedSeries,
            total: totalSeries
        ) {
            rows.append(row)
        }
        if let totalQueueJobs, let row = queueJobsCountRow(totalJobs: totalQueueJobs) {
            rows.append(row)
        }

        return ActiveJobStripStatusView(
            rows: rows,
            mode: "timing",
            showCancelIcon: true
        )
    }

    private static func timeProgressRow(
        elapsed: Double,
        estimate: Double?,
        showPendingStart: Bool = false
    ) -> ActiveJobStripRowKind {
        if let estimate, estimate > 0 {
            let total = elapsed + estimate
            let fill = total <= 0 ? 0 : Int(round(100.0 * elapsed / total))
            return .bar(
                label: "Elapsed:",
                prefix: GenerationTimingStats.formatDuration(elapsed),
                postfix: GenerationTimingStats.formatDuration(estimate),
                fillPercent: fill,
                slotText: "",
                showPendingStart: showPendingStart
            )
        }
        if let estimate, estimate <= 0 {
            return .bar(
                label: "Elapsed:",
                prefix: GenerationTimingStats.formatDuration(elapsed),
                postfix: "",
                fillPercent: 0,
                slotText: completingSlotText,
                showPendingStart: showPendingStart
            )
        }
        return .bar(
            label: "Elapsed:",
            prefix: GenerationTimingStats.formatDuration(elapsed),
            postfix: "",
            fillPercent: 0,
            slotText: "",
            showPendingStart: showPendingStart
        )
    }

    private static func stepsProgressRow(step: Int, total: Int, label: String) -> ActiveJobStripRowKind? {
        guard total > 0 else { return nil }
        let stepClamped = max(0, min(step, total))
        if stepClamped > 0 {
            let remaining = total - stepClamped
            let fill = Int(round(100.0 * Double(stepClamped) / Double(total)))
            return .bar(
                label: label,
                prefix: "\(stepClamped)/\(total)",
                postfix: "\(remaining)",
                fillPercent: fill,
                slotText: "",
                showPendingStart: false
            )
        }
        return .bar(
            label: label,
            prefix: "0/\(total)",
            postfix: "",
            fillPercent: 0,
            slotText: "",
            showPendingStart: false
        )
    }

    private static func seriesProgressRow(completed: Int, total: Int) -> ActiveJobStripRowKind? {
        guard total > 1 else { return nil }
        if JobStepQueue.isSeriesContinuousCopies(total) {
            return .bar(label: "Copies:", prefix: "", postfix: "", fillPercent: 0, slotText: continuousSeriesSlotText, showPendingStart: false)
        }
        let done = max(0, min(completed, total))
        if done > 0 {
            let remaining = total - done
            let fill = Int(round(100.0 * Double(done) / Double(total)))
            return .bar(
                label: "Copies:",
                prefix: "\(done)/\(total)",
                postfix: "\(remaining)",
                fillPercent: fill,
                slotText: "",
                showPendingStart: false
            )
        }
        return .bar(label: "Copies:", prefix: "0/\(total)", postfix: "", fillPercent: 0, slotText: "", showPendingStart: false)
    }

    private static func queueJobsCountRow(totalJobs: Int) -> ActiveJobStripRowKind? {
        guard totalJobs > 0 else { return nil }
        return .count(label: "Jobs:", count: "\(totalJobs)")
    }
}
