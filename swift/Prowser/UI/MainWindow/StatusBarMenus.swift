import AppKit

/// NSMenu builders for status bar sections (Python `status_bar_config.py`).
@MainActor
enum StatusBarMenus {
    static func showSortMenu(appState: AppState, relativeTo view: NSView) {
        let menu = NSMenu()
        let currentMode = SortMode(rawValue: appState.config.string(forKey: "sort_mode", default: "date")) ?? .date
        let reversed = appState.config.bool(forKey: "sort_reversed", default: false)

        addSortItem(menu, title: "Date ↑ (Newest First)", mode: .date, reversed: false, currentMode: currentMode, currentReversed: reversed, appState: appState)
        addSortItem(menu, title: "Date ↓ (Oldest First)", mode: .date, reversed: true, currentMode: currentMode, currentReversed: reversed, appState: appState)
        addSortItem(menu, title: "EXIF Month ↑ (Newest First)", mode: .exifDate, reversed: false, currentMode: currentMode, currentReversed: reversed, appState: appState)
        addSortItem(menu, title: "EXIF Month ↓ (Oldest First)", mode: .exifDate, reversed: true, currentMode: currentMode, currentReversed: reversed, appState: appState)
        addSortItem(menu, title: "EXIF Year ↑ (Newest First)", mode: .exifYear, reversed: false, currentMode: currentMode, currentReversed: reversed, appState: appState)
        addSortItem(menu, title: "EXIF Year ↓ (Oldest First)", mode: .exifYear, reversed: true, currentMode: currentMode, currentReversed: reversed, appState: appState)
        addSortItem(menu, title: "Name ↑ (A-Z)", mode: .name, reversed: false, currentMode: currentMode, currentReversed: reversed, appState: appState)
        addSortItem(menu, title: "Name ↓ (Z-A)", mode: .name, reversed: true, currentMode: currentMode, currentReversed: reversed, appState: appState)
        addSortItem(menu, title: "Size ↑ (Largest First)", mode: .size, reversed: false, currentMode: currentMode, currentReversed: reversed, appState: appState)
        addSortItem(menu, title: "Size ↓ (Smallest First)", mode: .size, reversed: true, currentMode: currentMode, currentReversed: reversed, appState: appState)
        addSortItem(menu, title: "Random", mode: .random, reversed: false, currentMode: currentMode, currentReversed: reversed, appState: appState)
        addSortItem(menu, title: "Custom", mode: .custom, reversed: false, currentMode: currentMode, currentReversed: reversed, appState: appState)

        popUp(menu, relativeTo: view)
    }

    static func showFilterMenu(appState: AppState, relativeTo view: NSView) {
        let menu = NSMenu()
        let saved = appState.config.getSavedFilters()
        let current = appState.filterSettings.filterPattern
        let currentNormalized = normalizeForComparison(current)

        menu.addItem(makeAction(title: "Edit...", handler: {
            appState.presentFilterEditSheet()
        }))

        menu.addItem(.separator())

        let noFilter = makeAction(title: "No Filter (*)", handler: {
            appState.applyFilenameFilterPattern("*")
        })
        noFilter.state = (current == "*" || currentNormalized == "*") ? .on : .off
        menu.addItem(noFilter)

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

        if !filtersToShow.isEmpty {
            menu.addItem(.separator())
        }

        for pattern in filtersToShow {
            let display = displayPattern(pattern)
            let item = makeAction(title: display, handler: {
                appState.applyFilenameFilterPattern(FilterPatternFormatting.normalizeForMatching(pattern))
            })
            if normalizeForComparison(pattern) == currentNormalized {
                item.state = .on
            }
            menu.addItem(item)
        }

        popUp(menu, relativeTo: view)
    }

    static func showFileCountMenu(appState: AppState, relativeTo view: NSView) {
        let menu = NSMenu()
        let enabled = appState.config.bool(forKey: "background_clip_enabled", default: false)
        let title = enabled ? "Turn off Background Extracts" : "Turn on Background Extracts"
        menu.addItem(makeAction(title: title, handler: {
            let next = !enabled
            appState.config.updateSetting("background_clip_enabled", value: next)
            appState.workers.reloadSettings(config: appState.config)
            appState.status.show(next ? "Background extracts enabled" : "Background extracts disabled")
        }))
        popUp(menu, relativeTo: view)
    }

    static func showDateMenu(appState: AppState, relativeTo view: NSView) {
        let menu = NSMenu()
        let useExif = appState.config.useExifDate

        let fileDate = makeAction(title: "Always Use File Date", handler: {
            appState.setUseExifDate(false)
        })
        fileDate.state = useExif ? .off : .on
        menu.addItem(fileDate)

        let exifDate = makeAction(title: "Use EXIF Date if Available", handler: {
            appState.setUseExifDate(true)
        })
        exifDate.state = useExif ? .on : .off
        menu.addItem(exifDate)

        popUp(menu, relativeTo: view)
    }

    private static func addSortItem(
        _ menu: NSMenu,
        title: String,
        mode: SortMode,
        reversed: Bool,
        currentMode: SortMode,
        currentReversed: Bool,
        appState: AppState
    ) {
        let item = makeAction(title: title, handler: {
            appState.applySortMode(mode, reversed: reversed)
        })
        if mode == currentMode && reversed == currentReversed {
            item.state = .on
        }
        menu.addItem(item)
    }

    private static func makeAction(title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(StatusBarMenuHandler.invoke(_:)), keyEquivalent: "")
        item.target = StatusBarMenuHandler.shared
        item.tag = StatusBarMenuHandler.shared.register(handler)
        return item
    }

    private static func popUp(_ menu: NSMenu, relativeTo view: NSView) {
        let point = NSPoint(x: view.bounds.minX, y: view.bounds.maxY + 4)
        menu.popUp(positioning: nil, at: point, in: view)
    }

    private static func normalizeForComparison(_ pattern: String) -> String {
        var value = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("*") { value = String(value.dropLast()) }
        if value.isEmpty { return "*" }
        return value
    }

    private static func displayPattern(_ pattern: String) -> String {
        if pattern.contains("*") || pattern.contains("?") || pattern.contains("[") {
            return pattern
        }
        return pattern + "*"
    }
}

@MainActor
private final class StatusBarMenuHandler: NSObject {
    static let shared = StatusBarMenuHandler()
    private var handlers: [Int: () -> Void] = [:]
    private var nextID = 1

    func register(_ handler: @escaping () -> Void) -> Int {
        let id = nextID
        nextID += 1
        handlers[id] = handler
        return id
    }

    @objc func invoke(_ sender: NSMenuItem) {
        handlers[sender.tag]?()
        handlers.removeValue(forKey: sender.tag)
    }
}
