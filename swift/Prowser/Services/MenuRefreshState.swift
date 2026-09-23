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
    private var keyWindowObservers: [NSObjectProtocol] = []

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
        destinationsMenuVisible = appState.config.string(
            forKey: "destination_menu_action",
            default: "move"
        ) != "none"
        refreshDeleteExifDate(appState: appState)
        refreshExcludeFilesFromView(appState: appState)
    }

    func refreshExcludeFilesFromView(appState: AppState) {
        excludeFilesFromViewVisible = appState.fileData.currentViewMode == .thumbnail
            && ThumbnailExcludeService.hasEnabledExcludeRules(config: appState.config)
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
        ]
    }
}
