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

    /// Fallback content height below the pane titlebar when live measurement is unavailable.
    func estimatedContentHeight(jobCount: Int, isProcessing: Bool) -> CGFloat {
        JobQueuePaneMetrics.contentHeight(
            mode: self,
            cardStackHeight: 0,
            activeStripHeight: 0,
            jobCount: jobCount,
            isProcessing: isProcessing,
            showsActiveStrip: isProcessing || jobCount > 0,
            hasMeasuredCards: false,
            includesToolbar: false
        )
    }
}

/// Port of `job_queue_panel.py` pane content height helpers.
enum JobQueuePaneMetrics {
    static let panelPadding: CGFloat = 8
    static let vstackSpacing: CGFloat = 4
    static let bottomSlack: CGFloat = 5
    static let emptyStateHeight: CGFloat = 18
    static let fallbackStripHeight: CGFloat = 36
    static let fallbackSingleCardHeight: CGFloat = 96
    /// Matches ``JobPaneToolbar`` row height + bottom margin in ``jobs_toolbar.py``.
    static let toolbarBlockHeight: CGFloat = 29

    static func contentHeight(
        mode: JobsQueueSizeMode,
        cardStackHeight: CGFloat,
        activeStripHeight: CGFloat,
        jobCount: Int,
        isProcessing: Bool,
        showsActiveStrip: Bool,
        hasMeasuredCards: Bool,
        includesToolbar: Bool = false
    ) -> CGFloat {
        let padding = panelPadding * 2
        let toolbar = includesToolbar ? toolbarBlockHeight : 0
        let stripBlock = stripBlockHeight(
            showsActiveStrip: showsActiveStrip,
            activeStripHeight: activeStripHeight
        )

        switch mode {
        case .strip:
            if showsActiveStrip {
                return padding + toolbar + stripBlock
            }
            if jobCount > 0 {
                return padding + toolbar + max(stripBlock, 22)
            }
            return padding + toolbar + emptyStateHeight

        case .one:
            let total = padding + toolbar + stripBlock
            if jobCount == 0 {
                return max(total + (isProcessing ? 22 : emptyStateHeight), padding + toolbar + emptyStateHeight)
            }
            let cardH = hasMeasuredCards ? cardStackHeight : fallbackSingleCardHeight
            return total + cardH + bottomSlack

        case .all:
            let total = padding + toolbar + stripBlock
            if jobCount == 0 {
                return max(total + (isProcessing ? 56 : emptyStateHeight), padding + toolbar + emptyStateHeight)
            }
            if jobCount <= 1 {
                let cardH = hasMeasuredCards ? cardStackHeight : fallbackSingleCardHeight
                return total + cardH + bottomSlack
            }
            let stackH = hasMeasuredCards
                ? cardStackHeight
                : min(320, 56 + CGFloat(jobCount) * fallbackSingleCardHeight * 0.75)
            return total + stackH + bottomSlack
        }
    }

    private static func stripBlockHeight(
        showsActiveStrip: Bool,
        activeStripHeight: CGFloat
    ) -> CGFloat {
        guard showsActiveStrip else { return 0 }
        let strip = activeStripHeight > 0 ? activeStripHeight : fallbackStripHeight
        return strip + vstackSpacing
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
