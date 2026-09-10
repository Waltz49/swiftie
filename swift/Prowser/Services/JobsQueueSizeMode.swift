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

    /// Estimated content height below the pane titlebar.
    func estimatedContentHeight(jobCount: Int, isProcessing: Bool) -> CGFloat {
        switch self {
        case .strip:
            return isProcessing || jobCount > 0 ? 36 : 22
        case .one:
            if jobCount == 0 { return isProcessing ? 56 : 22 }
            return 88
        case .all:
            if jobCount == 0 { return isProcessing ? 72 : 22 }
            return min(320, 56 + CGFloat(jobCount) * 72)
        }
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

    func splitterSizes(forKey key: String, default defaultValue: [CGFloat]) -> [CGFloat] {
        guard let raw = rawSettings()[key] as? [Any], raw.count == 3 else { return defaultValue }
        let sizes = raw.compactMap { value -> CGFloat? in
            if let intValue = value as? Int { return CGFloat(intValue) }
            if let doubleValue = value as? Double { return CGFloat(doubleValue) }
            return nil
        }
        guard sizes.count == 3, sizes.reduce(0, +) > 0 else { return defaultValue }
        return sizes
    }

    func saveSplitterSizes(_ key: String, sizes: [CGFloat]) {
        let ints = sizes.map { Int(round($0)) }
        updateSetting(key, value: ints)
    }
}
