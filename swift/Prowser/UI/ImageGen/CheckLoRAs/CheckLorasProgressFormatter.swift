import Foundation

enum CheckLorasProgressFormatter {
    static func statusText(
        message: [String: Any],
        elapsed: TimeInterval,
        eta: TimeInterval?
    ) -> String {
        let phase = message["phase"] as? String ?? ""
        let stats = message["stats"] as? [String: Any] ?? [:]
        var lines: [String] = []

        switch phase {
        case "scan":
            lines.append("Scanning LoRA weights (cache + top-level Downloads)…")
            appendScanLines(stats: stats, into: &lines)
            appendTimingLine(elapsed: elapsed, eta: eta, into: &lines)
        case "downloads":
            lines.append("Removing duplicate Downloads LoRAs…")
            let scanned = int(stats["downloads_scanned"])
            let deduped = int(stats["downloads_deduped"])
            lines.append("Downloads scanned: \(scanned) · Duplicates removed: \(deduped)")
            appendTimingLine(elapsed: elapsed, eta: eta, into: &lines)
        default:
            appendProbeLines(
                message: message,
                stats: stats,
                elapsed: elapsed,
                eta: eta,
                into: &lines
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func appendTimingLine(
        elapsed: TimeInterval,
        eta: TimeInterval?,
        into lines: inout [String]
    ) {
        var timing = "Elapsed: \(formatDuration(elapsed))"
        if let eta, eta > 0 {
            timing += "  Est. Remaining: \(formatDuration(eta))"
        }
        lines.append(timing)
    }

    private static func appendScanLines(stats: [String: Any], into lines: inout [String]) {
        let lorasTotal = int(stats["loras_total"])
        let skippedDisk = int(stats["skipped_not_on_disk"])
        let modelsTotal = int(stats["models_total"])
        if lorasTotal > 0 || skippedDisk > 0 || int(stats["downloads_scanned"]) > 0 {
            lines.append(
                "To test: \(lorasTotal) · Not on disk (skipped): \(skippedDisk) · Installed models: \(modelsTotal)"
            )
            let discovered = int(stats["files_discovered"])
            if discovered > 0 {
                lines.append("Discovered: \(discovered) · MD5 deduped: \(int(stats["files_deduped"]))")
            }
            let unchanged = int(stats["skipped_unchanged"])
            if unchanged > 0 {
                lines.append("Unchanged (reuse history): \(unchanged)")
            }
            let dl = int(stats["downloads_scanned"])
            if dl > 0 {
                lines.append("Downloads scanned: \(dl) · Duplicates removed: \(int(stats["downloads_deduped"]))")
            }
            lines.append("GPU renders planned: \(int(stats["probes_total"]))")
            let hist = int(stats["skipped_unchanged_probes"])
            if hist > 0 {
                lines.append("History reuse planned: \(hist)")
            }
        }
    }

    private static func appendProbeLines(
        message: [String: Any],
        stats: [String: Any],
        elapsed: TimeInterval,
        eta: TimeInterval?,
        into lines: inout [String]
    ) {
        let activity = (stats["probe_activity"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let modelKey = message["model_key"] as? String ?? ""
        let modelIndex = int(stats["model_index_for_lora"])
        let modelsInPlan = max(int(stats["models_total"]), int(stats["models_for_lora"]), 1)
        let displayName = modelKey.isEmpty ? "—" : LoRAHFModelIDs.displayName(for: modelKey)
        lines.append("Model: \(modelIndex) of \(modelsInPlan) - \(displayName)")

        let loraPos = "\(int(stats["lora_index"]))/\(max(1, int(stats["loras_total"])))"
        let generatingName = generatingItemLabel(
            activity: activity,
            loraLabel: stats["current_lora_label"] as? String
        )
        lines.append("Generating: \(loraPos) \(generatingName)")

        lines.append("Newly Enabled: \(int(stats["newly_enabled_count"]))")
        appendTimingLine(elapsed: elapsed, eta: eta, into: &lines)
    }

    private static func generatingItemLabel(activity: String, loraLabel: String?) -> String {
        if activity.lowercased().contains("base image") {
            return "Base image"
        }
        let trimmed = (loraLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : trimmed
    }

    /// ETA from completed GPU renders only (skipped / history pairs are not timed work).
    static func estimatedGPURemaining(
        stats: [String: Any],
        gpuPhaseElapsed: TimeInterval?
    ) -> TimeInterval? {
        let gpuDone = int(stats["gpu_probes_done"])
        let gpuTotal = int(stats["probes_total"])
        guard gpuTotal > 0, gpuDone > 0, gpuDone < gpuTotal else { return nil }
        guard let gpuPhaseElapsed, gpuPhaseElapsed > 0 else { return nil }
        return (gpuPhaseElapsed / Double(gpuDone)) * Double(gpuTotal - gpuDone)
    }

    static func progressValue(message: [String: Any]) -> (done: Int, total: Int) {
        let stats = message["stats"] as? [String: Any] ?? [:]
        let phase = message["phase"] as? String ?? ""
        let total = max(1, (message["work_total"] as? NSNumber)?.intValue ?? int(stats["probes_total"]))
        if phase == "probe" {
            var current = int(stats["probes_done"])
            let probeCurrent = int(stats["probe_current"])
            if probeCurrent > 0, current == 0 {
                current = max(0, probeCurrent - 1)
            }
            return (min(current, total), total)
        }
        return (0, total)
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 {
            return "\(total / 3600)h \((total % 3600) / 60)m"
        }
        if total >= 60 {
            return "\(total / 60)m \(total % 60)s"
        }
        return "\(total)s"
    }

    private static func int(_ value: Any?) -> Int {
        if let n = value as? NSNumber { return n.intValue }
        if let i = value as? Int { return i }
        return 0
    }
}
