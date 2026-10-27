import AppKit

/// Shared filter preset list for status bar popup and menu bar Filter menu (Python `status_bar_config.py`).
@MainActor
enum FilterPresetMenu {
    struct PresetEntry {
        let displayTitle: String
        let applyPattern: String
        let isSelected: Bool
    }

    struct Model {
        let noFilterSelected: Bool
        let presets: [PresetEntry]
    }

    static func model(appState: AppState) -> Model {
        let saved = appState.config.getSavedFilters()
        let current = appState.filterSettings.filterPattern
        let currentNormalized = normalizeForComparison(current)
        let noFilterSelected = current == "*" || currentNormalized == "*"

        var filtersToShow: [String] = []
        var seen = Set<String>()

        if currentNormalized != "*", !saved.contains(where: { normalizeForComparison($0) == currentNormalized }) {
            filtersToShow.append(currentNormalized)
            seen.insert(currentNormalized)
        }

        for pattern in saved {
            let normalized = normalizeForComparison(pattern)
            guard !normalized.isEmpty, normalized != "*", !seen.contains(normalized) else { continue }
            filtersToShow.append(normalized)
            seen.insert(normalized)
        }

        let presets = filtersToShow.map { pattern in
            PresetEntry(
                displayTitle: displayPattern(pattern),
                applyPattern: FilterPatternFormatting.normalizeForMatching(pattern),
                isSelected: normalizeForComparison(pattern) == currentNormalized
            )
        }

        return Model(noFilterSelected: noFilterSelected, presets: presets)
    }

    static func appendItems(to menu: NSMenu, appState: AppState, makeAction: (String, @escaping () -> Void) -> NSMenuItem) {
        let snapshot = model(appState: appState)

        menu.addItem(makeAction("Edit...", {
            appState.presentFilterEditSheet()
        }))

        menu.addItem(.separator())

        let noFilter = makeAction("No Filter (*)", {
            appState.applyFilenameFilterPattern("*")
        })
        noFilter.state = snapshot.noFilterSelected ? NSControl.StateValue.on : NSControl.StateValue.off
        menu.addItem(noFilter)

        if !snapshot.presets.isEmpty {
            menu.addItem(.separator())
        }

        for entry in snapshot.presets {
            let item = makeAction(entry.displayTitle, {
                appState.applyFilenameFilterPattern(entry.applyPattern)
            })
            if entry.isSelected {
                item.state = NSControl.StateValue.on
            }
            menu.addItem(item)
        }
    }

    static func normalizeForComparison(_ pattern: String) -> String {
        var value = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("*") { value = String(value.dropLast()) }
        if value.isEmpty { return "*" }
        return value
    }

    static func displayPattern(_ pattern: String) -> String {
        if pattern.contains("*") || pattern.contains("?") || pattern.contains("[") {
            return pattern
        }
        return pattern + "*"
    }
}
