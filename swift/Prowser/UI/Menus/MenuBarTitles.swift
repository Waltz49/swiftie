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

    /// Removes SwiftUI's auto-created File/Edit/View menus when our guarded copies exist.
    @MainActor
    static func removeDuplicateStandardMenus() {
        guard let mainMenu = NSApp.mainMenu else { return }

        let guardedPresent = Set(
            mainMenu.items.compactMap { item -> String? in
                let title = item.title
                guard title.hasSuffix(systemInjectionGuard) else { return nil }
                return String(title.dropLast(systemInjectionGuard.count))
            }
        )

        for item in mainMenu.items.reversed() {
            let title = item.title
            guard plainSystemMenus.contains(title), guardedPresent.contains(title) else { continue }
            mainMenu.removeItem(item)
        }
    }
}
