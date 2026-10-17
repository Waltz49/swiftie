import CoreGraphics
import Foundation

/// Port of `imagegen_plugins/job_queue_panel.py` queue size modes.
enum JobsQueueSizeMode: String, CaseIterable {
    case all
    case one
    case strip

    static func normalize(_ raw: String?) -> JobsQueueSizeMode {
        guard let raw, let mode = JobsQueueSizeMode(rawValue: raw) else { return .all }
        return mode
    }

    func next() -> JobsQueueSizeMode {
        let modes = Self.allCases
        guard let index = modes.firstIndex(of: self) else { return .all }
        return modes[(index + 1) % modes.count]
    }
}

/// Port of `job_queue_panel.py` pane content height helpers.
enum JobQueuePaneMetrics {
    static let panelPadding: CGFloat = 8
    static let vstackSpacing: CGFloat = 4 // spacing between active strip and queue block in ``JobQueuePanelView``
    /// Matches ``JobPaneToolbar`` row height + bottom margin in ``jobs_toolbar.py``.
    static let toolbarBlockHeight: CGFloat = 29
    /// Reserved bottom buffer for sidebar auto-resize; matches ``ChromeLayoutAnimator.statusBarHeight``.
    static let statusBarFitBufferHeight: CGFloat = 24
    /// Port of ``empty_queue_label_height_px`` (~1.5 caption lines).
    static let emptyQueueLabelHeight: CGFloat = 20

    /// Port of ``empty_state_height_hint`` (label + optional jobs toolbar).
    static func emptyStateClientHeight(toolbarVisible: Bool) -> CGFloat {
        var height = emptyQueueLabelHeight
        if toolbarVisible {
            height += toolbarBlockHeight
        }
        return height
    }

    /// Bottom inset for sidebar pane auto-resize: pane border, fit slack, and status-bar row buffer.
    static func paneAutoResizeBottomInset(
        mode: JobsQueueSizeMode,
        shrinkWrap: Bool,
        jobCount: Int,
        viewBorderWidthPx: Int,
        statusBarHeight: CGFloat
    ) -> CGFloat {
        if mode == .strip { return 0 }
        let border = CGFloat(max(1, viewBorderWidthPx))
        if shrinkWrap {
            return border + max(0, statusBarHeight)
        }
        guard jobCount > 0 else { return border }
        return border
            + JobQueueLayout.paneFitBottomSlack
            + (statusBarHeight > 0 ? statusBarFitBufferHeight : 0)
    }

    /// Port of ``ActiveJobStripWidget.content_height`` / ``_active_strip_block_height`` using strip row layout.
    static func estimatedActiveStripHeight(for strip: ActiveJobStripStatusView) -> CGFloat {
        if strip.isEmpty { return 0 }
        let rowLine = max(JobQueueLayout.stripBarHeight, ceil(JobQueueLayout.fontSize * 1.25))
        var content: CGFloat = 0
        var rowCount = 0
        for row in strip.rows {
            switch row {
            case .bar, .count:
                content += rowLine
                rowCount += 1
            }
        }
        if rowCount > 1 {
            content += CGFloat(rowCount - 1) * 2
        }
        if !strip.cooldownText.isEmpty {
            if rowCount > 0 { content += 2 }
            content += rowLine + 4
        }
        // Match ``ActiveJobStripNSView.measuredContentHeight`` frame chrome (border + inner padding).
        return 10 + max(content, 18)
    }
}

enum JobsDisplayMode: String {
    case pane
    case panel

    static func normalize(_ raw: String?) -> JobsDisplayMode {
        raw == JobsDisplayMode.panel.rawValue ? .panel : .pane
    }
}

@MainActor
enum JobsQueueSizePersistence {
    static func load(config: AppConfig) -> JobsQueueSizeMode {
        JobsQueueSizeMode.normalize(config.imageGenString("job_queue_size_mode", default: "all"))
    }

    static func save(_ mode: JobsQueueSizeMode, config: AppConfig) {
        config.setImageGenValue("job_queue_size_mode", value: mode.rawValue)
    }
}

extension AppConfig {
    func imageGenString(_ key: String, default defaultValue: String = "") -> String {
        let imagegen = rawSettings()["imagegen"] as? [String: Any]
        return imagegen?[key] as? String ?? defaultValue
    }

    func setImageGenValue(_ key: String, value: Any) {
        var imagegen = rawSettings()["imagegen"] as? [String: Any] ?? [:]
        imagegen[key] = value
        updateSetting("imagegen", value: imagegen)
    }

}
