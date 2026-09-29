import AppKit
import Foundation

/// Dynamic menu enable/visibility flags (Python `menu_manager.py` `aboutToShow` handlers).
@MainActor
@Observable
final class MenuRefreshState {
    private weak var appState: AppState?

    var canViewTrash = false
    var moveWorkFilesVisible = false
    var deleteExifDateEnabled = false
    var deleteExifDateTitle = "Delete EXIF Date from File…"
    var destinationsMenuVisible = true
    /// False while a dialog/settings/about window is key (`KeyboardHandlerController` parity).
    var browserWindowShortcutsEnabled = true
    /// SwiftUI menu items — lenient while menu bar tracking resigns the main window key.
    var browserMenuCommandsEnabled = true
    /// Tools → Exclude Thumbs from View (⌘X); thumbnail view only when exclude rules are enabled.
    var excludeFilesFromViewVisible = false
    var moveToTrashMenuTitle = "Move File to Trash"
    var quickMassRenameMenuVisible = false
    var lockUnlockMenuVisible = false
    private var keyWindowObservers: [NSObjectProtocol] = []
    private var lastDestinationMenuAction: String?

    func bind(_ appState: AppState) {
        self.appState = appState
        installKeyWindowObservers()
        refreshAll()
    }

    /// Python `MenuManager.prime_menu_keys_for_view_change` — without trash/volume scans.
    func primeForViewChange(appState: AppState) {
        refreshBrowserWindowShortcuts()
        refreshExcludeFilesFromView(appState: appState)
        refreshDeleteExifDate(appState: appState)
        refreshMoveToTrashMenu(appState: appState)
        refreshQuickMassRenameMenu(appState: appState)
        refreshLockUnlockMenu(appState: appState)
    }

    func refreshAll() {
        guard let appState else { return }
        refreshBrowserWindowShortcuts()
        canViewTrash = TrashDirectoryService.hasReadableTrashWithImages(
            extensions: appState.config.imageExtensions
        )
        moveWorkFilesVisible = MoveWorkFilesService.canMoveWorkFiles(
            currentDirectory: appState.fileData.currentDirectory
        )
        let destAction = appState.config.string(forKey: "destination_menu_action", default: "move")
        if let lastDestinationMenuAction, destAction != lastDestinationMenuAction {
            appState.bumpMenuCommandsRevision()
        }
        lastDestinationMenuAction = destAction
        destinationsMenuVisible = destAction != "none"
        refreshDeleteExifDate(appState: appState)
        refreshExcludeFilesFromView(appState: appState)
        refreshMoveToTrashMenu(appState: appState)
        refreshQuickMassRenameMenu(appState: appState)
        refreshLockUnlockMenu(appState: appState)
    }

    func refreshDeleteExifDate(appState: AppState) {
        guard appState.fileData.currentViewMode == .thumbnail, !appState.specificFilesActive else {
            deleteExifDateEnabled = false
            deleteExifDateTitle = "Delete EXIF Date from File…"
            return
        }
        let paths = SelectionService.selectedFilesOrCurrent(appState: appState)
        let withExif = paths.filter { ExifService.exifTimestamp(path: $0) != nil }
        deleteExifDateEnabled = !withExif.isEmpty
        deleteExifDateTitle = withExif.count > 1
            ? "Delete EXIF Dates from Files…"
            : "Delete EXIF Date from File…"
    }

    func refreshExcludeFilesFromView(appState: AppState) {
        excludeFilesFromViewVisible = appState.fileData.currentViewMode == .thumbnail
            && ThumbnailExcludeService.hasEnabledExcludeRules(config: appState.config)
    }

    func refreshMoveToTrashMenu(appState: AppState) {
        let paths = SelectionService.selectedFilesOrCurrent(appState: appState)
        let confirm = appState.config.bool(forKey: "confirm_delete", default: true)
        let ellipsis = confirm ? "…" : ""
        moveToTrashMenuTitle = paths.count > 1
            ? "Move Files to Trash\(ellipsis)"
            : "Move File to Trash\(ellipsis)"
    }

    func refreshQuickMassRenameMenu(appState: AppState) {
        let visible = appState.config.bool(forKey: "allow_quick_mass_rename", default: false)
        guard visible != quickMassRenameMenuVisible else { return }
        quickMassRenameMenuVisible = visible
        appState.bumpMenuCommandsRevision()
    }

    func refreshLockUnlockMenu(appState: AppState) {
        let allow = appState.config.bool(forKey: "allow_thumbnail_locking", default: false)
        let mode = appState.fileData.currentViewMode
        let visible = allow && (mode == .thumbnail || mode == .browse)
        guard visible != lockUnlockMenuVisible else { return }
        lockUnlockMenuVisible = visible
        appState.bumpMenuCommandsRevision()
    }

    func refreshBrowserWindowShortcuts() {
        let shortcuts = BrowserWindowIdentity.browserWindowOwnsShortcuts()
        let menus = BrowserWindowIdentity.browserMenuCommandsEnabled()
        let changed = browserWindowShortcutsEnabled != shortcuts
            || browserMenuCommandsEnabled != menus
        browserWindowShortcutsEnabled = shortcuts
        browserMenuCommandsEnabled = menus
        if changed {
            appState?.bumpMenuCommandsRevision()
        }
    }

    private func installKeyWindowObservers() {
        guard keyWindowObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let refresh: () -> Void = { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshBrowserWindowShortcuts()
            }
        }
        keyWindowObservers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in refresh() },
            // Skip didResignKey — main resigns before menu tracking's transient key is key and
            // would briefly disable SwiftUI Command menus (249afee menu refresh regression).
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in refresh() },
            center.addObserver(
                forName: .prowserBrowserShortcutGateShouldRefresh,
                object: nil,
                queue: .main
            ) { _ in refresh() },
        ]
    }
}
