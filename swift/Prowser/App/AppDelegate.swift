import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?
    private var instanceLock: InstanceLock?
    private var pendingOpenPaths: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let appState else { return }

        let lockPath = appState.config.dataDirectory
            .appendingPathComponent("instance.lock")

        let lock = InstanceLock(lockURL: lockPath)
        if lock.tryAcquire() {
            instanceLock = lock
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            scheduleMenuBarDeduplication()
            applyLaunchOptions(appState)
            appState.imageGen.setDeferredQuitAppState(appState)
            appState.imageGen.onDeferredQuitComplete = {
                NSApp.terminate(nil)
            }
        } else {
            let message = LaunchMessage.from(launchOptions: appState.launchOptions)
            if InstanceLock.forwardToRunningInstance(
                message: message,
                pipePath: appState.config.namedPipePath
            ) {
                NSApp.terminate(nil)
                return
            }
            StyledMessageDialog.showWarning(
                title: "Prowser is already running",
                message: "Could not forward the open request to the running instance."
            )
            NSApp.terminate(nil)
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        NSApp.activate(ignoringOtherApps: true)
        if let appState {
            appState.openPaths(filenames)
        } else {
            pendingOpenPaths.append(contentsOf: filenames)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let appState, let lastDir = appState.config.lastDirectory,
           FileManager.default.fileExists(atPath: lastDir) {
            appState.loadDirectory(lastDir)
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState else { return .terminateNow }
        if appState.confirmQuitIfRunning() {
            return .terminateNow
        }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let appState {
            let path = appState.fileData.currentImagePath
            let directory = appState.fileData.currentDirectory
            if path != nil || directory != nil {
                appState.config.saveRestoreState(
                    filePath: path,
                    directory: directory,
                    viewMode: appState.fileData.currentViewMode.rawValue,
                    macosSpaceMode: WindowFullscreen.isInMacOSSpace
                )
            }
        }
        appState?.prepareForApplicationExit()
        appState?.theme.commitPreview()
        appState?.config.saveSettings()
        appState?.persistAllSidebarLayout()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        scheduleMenuBarDeduplication()
    }

    private func scheduleMenuBarDeduplication() {
        DispatchQueue.main.async {
            MenuBarTitles.removeDuplicateStandardMenus()
        }
    }

    private func applyLaunchOptions(_ appState: AppState) {
        if !pendingOpenPaths.isEmpty {
            appState.openPaths(pendingOpenPaths)
            pendingOpenPaths.removeAll()
        } else if !appState.launchOptions.paths.isEmpty {
            appState.openPaths(appState.launchOptions.paths)
        } else if appState.config.restoreState, let snapshot = appState.config.getRestoreState() {
            if let file = snapshot.lastFile, FileManager.default.fileExists(atPath: file) {
                appState.openPaths([file])
            } else if let lastDir = snapshot.lastDirectory, FileManager.default.fileExists(atPath: lastDir) {
                appState.loadDirectory(lastDir)
            }
            if let mode = ViewMode(rawValue: snapshot.lastViewMode) {
                appState.fileData.setViewMode(mode)
            }
            if let file = snapshot.lastFile, FileManager.default.fileExists(atPath: file) {
                appState.fileData.setCurrentImagePath(file)
            }
        }

        if appState.launchOptions.debug {
            appState.config.setValue(true, forKey: "debug_mode")
        }

        let restore = appState.config.rawSettings()["restore_state"] as? [String: Any]
        let savedSpace = restore?["last_macos_space_mode"] as? Bool
        WindowFullscreen.applyLaunchPreference(
            noFullscreen: appState.launchOptions.noFullscreen,
            restoreState: appState.config.restoreState,
            savedMacOSSpace: savedSpace
        )

        let capturedState = appState
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { _ in
                WindowFullscreen.persistMacOSSpaceMode(config: capturedState.config)
            }
        }
    }
}
