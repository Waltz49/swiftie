import Foundation

/// Filter pattern and tree filter mode. Mirrors Python `FilterSettingsModel`.
@Observable
@MainActor
final class FilterSettingsModel {
    private weak var config: AppConfig?

    private(set) var filterPattern: String = "*"
    private(set) var filteredTree: String = "images"

    init(config: AppConfig?) {
        self.config = config
    }

    func bindConfig(_ config: AppConfig) {
        self.config = config
    }

    func loadFromConfig() {
        guard let config else { return }
        setFilterPattern(config.filterPattern ?? "*", persist: false)
        setFilteredTree(config.filteredTree, persist: false)
    }

    func setFilterPattern(_ pattern: String?, persist: Bool = true, notify: Bool = true) {
        let normalized = Self.normalizeFilterPattern(pattern)
        guard normalized != filterPattern else { return }
        filterPattern = normalized
        if persist { config?.updateSetting("filter_pattern", value: normalized) }
        if notify {
            NotificationCenter.default.post(name: .prowserFilterPatternChanged, object: normalized)
        }
    }

    func setFilteredTree(_ mode: String, persist: Bool = true, notify: Bool = true) {
        let normalized = Self.validTreeModes.contains(mode) ? mode : "images"
        guard normalized != filteredTree else { return }
        filteredTree = normalized
        if persist { config?.updateSetting("filtered_tree", value: normalized) }
        if notify {
            NotificationCenter.default.post(name: .prowserFilterTreeModeChanged, object: normalized)
        }
    }

    static let validTreeModes: Set<String> = ["all", "images", "use_filter"]

    static func normalizeFilterPattern(_ pattern: String?) -> String {
        guard let pattern, !pattern.isEmpty else { return "*" }
        return pattern
    }
}

extension Notification.Name {
    static let prowserFilterPatternChanged = Notification.Name("prowser.filterPatternChanged")
    static let prowserFilterTreeModeChanged = Notification.Name("prowser.filterTreeModeChanged")
}
