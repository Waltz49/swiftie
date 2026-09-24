import AppKit

/// Right-click / control-click menu for file tree directory rows.
@MainActor
enum FileTreeContextMenu {
    static func show(for event: NSEvent, directoryPath: String, in view: NSView, appState: AppState) {
        let menu = buildMenu(directoryPath: directoryPath, appState: appState)
        FileTreeMenuActions.shared.appState = appState
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    static func buildMenu(directoryPath: String, appState: AppState) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let restricted = FileTreePathRestrictions.isRootOrSystemVolume(directoryPath)
        let canRename = FileTreePathRestrictions.canRenameDirectory(directoryPath)

        addAction(
            menu,
            title: "Rename...",
            shortcut: "F2",
            enabled: canRename,
            representedObject: directoryPath,
            action: #selector(FileTreeMenuActions.renameDirectory(_:))
        )
        addAction(
            menu,
            title: "Search by Description...",
            shortcut: "⌘F",
            enabled: !restricted,
            representedObject: directoryPath,
            action: #selector(FileTreeMenuActions.searchByDescription(_:))
        )
        if FaceRecognitionCapabilities.facesUIEnabled(launchOptions: appState.launchOptions) {
            addAction(
                menu,
                title: "Search for Known Person…",
                shortcut: "⌘P",
                enabled: !restricted,
                representedObject: directoryPath,
                action: #selector(FileTreeMenuActions.searchByPerson(_:))
            )
        }
        addAction(
            menu,
            title: "Copy Directory Path",
            shortcut: "⌘C",
            representedObject: directoryPath,
            action: #selector(FileTreeMenuActions.copyDirectoryPath(_:))
        )
        addAction(
            menu,
            title: "Open in Finder",
            representedObject: directoryPath,
            action: #selector(FileTreeMenuActions.openInFinder(_:))
        )
        addAction(
            menu,
            title: "Show All Images inc. Subdirs",
            shortcut: "⇧A",
            enabled: !restricted,
            representedObject: directoryPath,
            action: #selector(FileTreeMenuActions.showAllImages(_:))
        )
        addAction(
            menu,
            title: "Find Duplicate Image Files",
            shortcut: "⇧F",
            enabled: !restricted,
            representedObject: directoryPath,
            action: #selector(FileTreeMenuActions.findDuplicates(_:))
        )
        addAction(
            menu,
            title: "Find VisuallySimilar Image Files",
            enabled: !restricted,
            representedObject: directoryPath,
            action: #selector(FileTreeMenuActions.findSimilarImages(_:))
        )
        addAction(
            menu,
            title: "Clear Cache",
            enabled: !restricted,
            representedObject: directoryPath,
            action: #selector(FileTreeMenuActions.clearCache(_:))
        )
        stripMenuIcons(menu)
        return menu
    }

    private static func addAction(
        _ menu: NSMenu,
        title: String,
        shortcut: String? = nil,
        enabled: Bool = true,
        representedObject: Any?,
        action: Selector
    ) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        if let shortcut, !shortcut.isEmpty {
            NSMenuShortcutSupport.apply(display: shortcut, to: item)
        }
        item.target = FileTreeMenuActions.shared
        item.isEnabled = enabled
        item.representedObject = representedObject
    }

    private static func stripMenuIcons(_ menu: NSMenu) {
        for item in menu.items {
            item.image = nil
            item.onStateImage = nil
            if let submenu = item.submenu {
                stripMenuIcons(submenu)
            }
        }
    }
}

@MainActor
final class FileTreeMenuActions: NSObject {
    static let shared = FileTreeMenuActions()
    weak var appState: AppState?

    @objc func renameDirectory(_ sender: NSMenuItem) {
        guard let appState, let path = sender.representedObject as? String else { return }
        appState.fileOperations.beginRename(path: path)
        appState.fileTreeReloadToken += 1
    }

    @objc func copyDirectoryPath(_ sender: NSMenuItem) {
        guard let appState, let path = sender.representedObject as? String else { return }
        appState.fileOperations.copyPathsToClipboard([path])
    }

    @objc func searchByDescription(_ sender: NSMenuItem) {
        guard let appState, let path = sender.representedObject as? String else { return }
        if FileTreePathRestrictions.isRootOrSystemVolume(path) {
            showRestrictedAlert(path: path)
            return
        }
        appState.searchOperations.presentClipSearchDialog(directoryOverride: path)
    }

    @objc func searchByPerson(_ sender: NSMenuItem) {
        guard let appState, let path = sender.representedObject as? String else { return }
        if FileTreePathRestrictions.isRootOrSystemVolume(path) {
            showRestrictedAlert(path: path)
            return
        }
        appState.searchOperations.presentPersonSearchDialog(directoryOverride: path)
    }

    @objc func openInFinder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc func showAllImages(_ sender: NSMenuItem) {
        guard let appState, let path = sender.representedObject as? String else { return }
        appState.fileTreeOperations.showAllImages(in: path)
    }

    @objc func findDuplicates(_ sender: NSMenuItem) {
        guard let appState, let path = sender.representedObject as? String else { return }
        appState.fileTreeOperations.findDuplicateImages(in: path)
    }

    @objc func findSimilarImages(_ sender: NSMenuItem) {
        guard let appState, let path = sender.representedObject as? String else { return }
        appState.fileTreeOperations.findSimilarImages(in: path)
    }

    @objc func clearCache(_ sender: NSMenuItem) {
        guard let appState, let path = sender.representedObject as? String else { return }
        appState.fileTreeOperations.clearCache(for: path)
    }

    private func showRestrictedAlert(path: String) {
        StyledMessageDialog.showWarning(
            title: "Action Not Available",
            message: FileTreePathRestrictions.restrictedActionMessage(for: path)
        )
    }
}
