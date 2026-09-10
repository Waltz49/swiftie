import Foundation

/// Dynamic menu labels and checkmark state (Python `menu_manager.py` updates).
@MainActor
enum MenuStateHelpers {
    static func favoriteMenuLabel(slot: Int, config: AppConfig) -> String {
        let favorites = config.favoriteDirectories()
        guard slot >= 1, slot <= favorites.count else { return "\(slot). (empty)" }
        guard let path = favorites[slot - 1],
              !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else {
            return "\(slot). (empty)"
        }
        let expanded = (path as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir)
        let name = (expanded as NSString).lastPathComponent
        return "\(slot). \(name)"
    }

    static func favoriteIsEnabled(slot: Int, config: AppConfig) -> Bool {
        let favorites = config.favoriteDirectories()
        guard slot >= 1, slot <= favorites.count else { return false }
        guard let path = favorites[slot - 1], !path.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    static func destinationMenuLabel(slot: Int, config: AppConfig) -> String {
        let destinations = config.moveDestinations()
        let verb = config.string(forKey: "destination_menu_action", default: "move")
        let actionWord = verb == "copy" ? "Copy to" : "Move to"
        guard slot >= 1, slot <= destinations.count,
              let path = destinations[slot - 1],
              !path.isEmpty else {
            return "\(actionWord) Destination \(slot)"
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return "\(actionWord) Destination \(slot)"
        }
        let name = ((path as NSString).expandingTildeInPath as NSString).lastPathComponent
        return "\(actionWord) \(name)"
    }

    static func destinationIsVisible(slot: Int, config: AppConfig) -> Bool {
        let action = config.string(forKey: "destination_menu_action", default: "move")
        guard action != "none" else { return false }
        let destinations = config.moveDestinations()
        guard slot >= 1, slot <= destinations.count,
              let path = destinations[slot - 1],
              !path.isEmpty else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    static func sortMenuItemChecked(mode: SortMode, reversed: Bool, config: AppConfig) -> Bool {
        let currentMode = SortMode(rawValue: config.string(forKey: "sort_mode", default: "date")) ?? .date
        let currentReversed = config.bool(forKey: "sort_reversed", default: false)
        switch mode {
        case .random, .custom, .duplicates:
            return mode == currentMode
        default:
            return mode == currentMode && reversed == currentReversed
        }
    }

    static func chromeToggleTitle(appState: AppState) -> String {
        appState.isAnyChromeVisible ? "Hide Panes" : "Show Panes"
    }

    static func paneToggleLabel(_ name: String, visible: Bool) -> String {
        visible ? "Hide \(name)" : "Show \(name)"
    }
}
