import AppKit

/// Menu bar title helpers (Python `menu_manager.py` uses `Edit\u2060` / `View\u2060`).
enum MenuBarTitles {
    /// Zero-width word joiner — prevents macOS from treating the menu as a system menu.
    static let systemInjectionGuard = "\u{2060}"

    static func guarded(_ name: String) -> String {
        name + systemInjectionGuard
    }

    static let file = guarded("File")
    static let edit = guarded("Edit")
    static let view = guarded("View")

    private static let plainSystemMenus = ["File", "Edit", "View"]

    /// Strips the word joiner; AppKit may normalize `item.title` and drop `\u{2060}`.
    static func canonicalMenuTitle(_ title: String) -> String {
        title.replacingOccurrences(of: systemInjectionGuard, with: "")
    }

    /// Removes SwiftUI's auto-created File/Edit/View menus when our guarded copies exist.
    @MainActor
    static func removeDuplicateStandardMenus() {
        guard let mainMenu = NSApp.mainMenu else { return }

        for canonical in plainSystemMenus {
            let matches = mainMenu.items.filter { canonicalMenuTitle($0.title) == canonical }
            guard matches.count > 1 else { continue }
            guard let keeper = matches.max(by: { preferredStandardMenuScore($0) < preferredStandardMenuScore($1) }) else {
                continue
            }
            for item in matches where item !== keeper {
                mainMenu.removeItem(item)
            }
        }

        let guardedPresent = Set(
            mainMenu.items.compactMap { item -> String? in
                let canonical = canonicalMenuTitle(item.title)
                guard plainSystemMenus.contains(canonical) else { return nil }
                guard item.title.contains(systemInjectionGuard) else { return nil }
                return canonical
            }
        )

        for item in mainMenu.items.reversed() {
            let canonical = canonicalMenuTitle(item.title)
            guard plainSystemMenus.contains(canonical), guardedPresent.contains(canonical) else { continue }
            guard item.title == canonical else { continue }
            mainMenu.removeItem(item)
        }
    }

    /// Prefer Prowser's custom File/Edit/View menus over SwiftUI's empty system copies.
    private static func preferredStandardMenuScore(_ item: NSMenuItem) -> Int {
        let count = item.submenu?.items.count ?? 0
        let titles = Set(item.submenu?.items.map(\.title) ?? [])
        if titles.contains("Enter Image Viewer") { return 10_000 + count }
        if titles.contains("Open Directory…") { return 10_000 + count }
        if titles.contains("Rename with Custom Prefix…") { return 10_000 + count }
        if item.title.contains(systemInjectionGuard) { return 5_000 + count }
        return count
    }
}
