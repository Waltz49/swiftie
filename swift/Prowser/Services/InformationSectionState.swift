import Foundation

/// Persisted collapse state for information pane section headers.
@MainActor
final class InformationSectionState {
    static let defaultExpanded: [String: Bool] = [
        "filename": true,
        "references": true,
        "image_model": true,
        "prompt": true,
        "title": true,
        "description": true,
        "negative_prompt": true,
        "input_to_active_job": true,
        "output_of_active_job": true,
    ]

    private static let h4SectionKeyByTitle: [String: String] = [
        "references": "references",
        "image model": "image_model",
        "prompt": "prompt",
        "title": "title",
        "description": "description",
        "negative prompt": "negative_prompt",
    ]

    private let config: AppConfig
    private var cache: [String: Bool]?

    init(config: AppConfig) {
        self.config = config
    }

    func sectionExpanded(_ key: String) -> Bool {
        let state = loadState()
        return state[key] ?? Self.defaultExpanded[key] ?? true
    }

    func setSectionExpanded(_ key: String, expanded: Bool) {
        guard Self.defaultExpanded.keys.contains(key) else { return }
        var state = loadState()
        guard state[key] != expanded else { return }
        state[key] = expanded
        cache = state
        config.updateSetting("information_section_expanded", value: state)
    }

    func toggleSection(_ key: String, expandAll: Bool) {
        if expandAll {
            let target = !sectionExpanded(key)
            var state = loadState()
            var changed = false
            for sectionKey in Self.defaultExpanded.keys {
                if state[sectionKey] != target {
                    state[sectionKey] = target
                    changed = true
                }
            }
            guard changed else { return }
            cache = state
            config.updateSetting("information_section_expanded", value: state)
            return
        }
        setSectionExpanded(key, expanded: !sectionExpanded(key))
    }

    static func sectionKey(fromH4Title title: String) -> String? {
        let normalized = title
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return h4SectionKeyByTitle[normalized]
    }

    private func loadState() -> [String: Bool] {
        if let cache { return cache }
        var state = Self.defaultExpanded
        if let saved = config.rawSettings()["information_section_expanded"] as? [String: Bool] {
            for (key, value) in saved where state.keys.contains(key) {
                state[key] = value
            }
        }
        cache = state
        return state
    }
}
