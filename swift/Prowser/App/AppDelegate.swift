import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var appState: AppState!
    let isPrimary: Bool

    private var instanceLock: InstanceLock?
    private let launchOptions: LaunchOptions
    private let pipePath: String
    private var pendingOpenPaths: [String] = []
    private var didBecomePrimary = false
    private var launchCompleted = false
    private var pendingOpenFlush: DispatchWorkItem?
    private var menuBarDedupObserver: NSObjectProtocol?

    override init() {
        launchOptions = LaunchOptions.parse()
        let config = AppConfig(profilePath: launchOptions.profilePath)
        config.loadSettings()
        pipePath = config.namedPipePath

        let lockURL = config.dataDirectory.appendingPathComponent("instance.lock")
        let lock = InstanceLock(lockURL: lockURL)
        if lock.tryAcquire() {
            isPrimary = true
            instanceLock = lock
            appState = AppState(launchOptions: launchOptions)
        } else {
            isPrimary = false
        }
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard isPrimary else {
            NSApp.setActivationPolicy(.accessory)
            hideAllWindows()
            NotificationCenter.default.addObserver(
                forName: NSWindow.didExposeNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    (note.object as? NSWindow)?.orderOut(nil)
                    self?.hideAllWindows()
                }
            }
            return
        }
        applyApplicationIcon()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard isPrimary else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.forwardToRunningInstanceAndQuit()
            }
            return
        }

        didBecomePrimary = true
        launchCompleted = true
        NSApp.setActivationPolicy(.regular)
        applyApplicationIcon()
        NSApp.activate(ignoringOtherApps: true)
        installMenuBarDeduplication()
        installMainWindowGuard()
        applyLaunchOptions()
    }

    func applicationWillUpdate(_ notification: Notification) {
        guard isPrimary else { return }
        scheduleMenuBarDeduplication()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        enqueueOpenedURLs(urls)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        enqueueOpenedPaths(filenames)
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func enqueueOpenedURLs(_ urls: [URL]) {
        enqueueOpenedPaths(urls.filter(\.isFileURL).map(\.path))
    }

    func enqueueOpenedPaths(_ paths: [String]) {
        let cleaned = paths.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        pendingOpenPaths.append(contentsOf: cleaned)
        guard isPrimary else { return }
        NSApp.activate(ignoringOtherApps: true)
        guard didBecomePrimary else { return }
        schedulePendingOpenFlush()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard isPrimary else { return false }
        if !flag, let lastDir = appState.config.lastDirectory,
           FileManager.default.fileExists(atPath: lastDir) {
            appState.loadDirectory(lastDir)
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        isPrimary
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !isPrimary {
            WindowFullscreen.noteApplicationTerminating()
            return .terminateNow
        }
        if appState.confirmQuitIfRunning() {
            WindowFullscreen.noteApplicationTerminating()
            return .terminateNow
        }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard isPrimary else { return }
        appState.persistRestoreState(enableLaunchRestore: true)
        appState.prepareForApplicationExit()
        if appState.config.isSettingsSessionActive {
            appState.config.cancelSettingsSession()
            appState.theme.reload()
        }
        appState.config.saveSettings()
        appState.persistAllSidebarLayout()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard isPrimary else {
            hideAllWindows()
            return
        }
        scheduleMenuBarDeduplication()
        closeDuplicateMainWindows()
    }

    private func forwardToRunningInstanceAndQuit() {
        guard !launchCompleted else { return }
        launchCompleted = true
        hideAllWindows()
        let message = LaunchMessage.from(
            launchOptions: launchOptions,
            extraPaths: pendingOpenPaths
        )
        if InstanceLock.forwardToRunningInstance(
            message: message,
            pipePath: pipePath
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

    private func applyApplicationIcon() {
        if let icon = AppAssets.applicationIcon {
            NSApp.applicationIconImage = icon
        }
    }

    private func hideAllWindows() {
        for window in NSApp.windows {
            window.orderOut(nil)
        }
    }

    private func schedulePendingOpenFlush() {
        pendingOpenFlush?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushPendingOpens()
        }
        pendingOpenFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func flushPendingOpens() {
        let paths = Self.uniqued(pendingOpenPaths)
        pendingOpenPaths.removeAll()
        guard !paths.isEmpty else { return }
        appState.openPaths(paths)
    }

    /// SwiftUI can still create a transient duplicate main window for Finder Open With.
    private func installMainWindowGuard() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didExposeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.closeDuplicateMainWindows()
            }
        }
    }

    private func closeDuplicateMainWindows() {
        guard isPrimary else { return }
        let mainWindows = NSApp.windows.filter(isMainBrowserWindow)
        guard mainWindows.count > 1 else { return }
        let keeper = NSApp.keyWindow.flatMap { isMainBrowserWindow($0) ? $0 : nil }
            ?? mainWindows.first
        for window in mainWindows where window !== keeper {
            window.close()
        }
    }

    private func isMainBrowserWindow(_ window: NSWindow) -> Bool {
        BrowserWindowIdentity.isMainBrowserWindow(window)
    }

    private func installMenuBarDeduplication() {
        scheduleMenuBarDeduplication()
        guard menuBarDedupObserver == nil else { return }
        menuBarDedupObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didAddItemNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard self?.isPrimary == true else { return }
                guard let menu = note.object as? NSMenu, menu === NSApp.mainMenu else { return }
                self?.scheduleMenuBarDeduplication()
            }
        }
    }

    private func scheduleMenuBarDeduplication() {
        DispatchQueue.main.async { [weak self] in
            MenuBarTitles.removeDuplicateStandardMenus()
            self?.rewireStandardAboutMenuItems()
        }
    }

    /// Route Application-menu About to our custom dialog instead of `orderFrontStandardAboutPanel`.
    private func rewireStandardAboutMenuItems() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for topItem in mainMenu.items {
            guard let submenu = topItem.submenu else { continue }
            for item in submenu.items {
                guard item.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:)) else {
                    continue
                }
                item.target = self
                item.action = #selector(showCustomAboutPanel(_:))
            }
        }
    }

    @objc private func showCustomAboutPanel(_ sender: Any?) {
        appState.showAboutDialog()
    }

    private func applyLaunchOptions() {
        let finderPaths = Self.uniqued(pendingOpenPaths)
        pendingOpenPaths.removeAll()
        if !finderPaths.isEmpty {
            appState.openPaths(finderPaths)
        } else if !launchOptions.paths.isEmpty {
            appState.openPaths(launchOptions.paths)
        } else if let snapshot = appState.config.getRestoreState() {
            appState.restoreSession(snapshot)
        } else if let lastDir = appState.config.lastDirectory,
                  FileManager.default.fileExists(atPath: lastDir) {
            appState.loadDirectory(lastDir)
        }

        if !pendingOpenPaths.isEmpty {
            flushPendingOpens()
        }

        let restore = appState.config.rawSettings()["restore_state"] as? [String: Any]
        let savedSpace = restore?["last_macos_space_mode"] as? Bool
        WindowFullscreen.applyLaunchPreference(
            noFullscreen: launchOptions.noFullscreen,
            savedMacOSSpace: savedSpace
        )

        WindowFullscreen.installRestoreTracking(config: appState.config)
    }

    private static func uniqued(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths {
            let expanded = (path as NSString).expandingTildeInPath
            let normalized = URL(fileURLWithPath: expanded).standardizedFileURL.path
            if seen.insert(normalized).inserted {
                result.append(normalized)
            }
        }
        return result
    }
}

struct OptionalAppStateWindow<Content: View>: View {
    let appState: AppState?
    @ViewBuilder var content: (AppState) -> Content

    var body: some View {
        if let appState {
            content(appState)
        } else {
            SecondaryLaunchView()
        }
    }
}

struct PrimaryOrSecondaryRoot: View {
    let isPrimary: Bool
    let appState: AppState?

    var body: some View {
        if isPrimary, let appState {
            MainWindowView()
                .environment(appState)
        } else {
            SecondaryLaunchView()
        }
    }
}

struct SecondaryLaunchView: View {
    var body: some View {
        Color.clear.frame(width: 1, height: 1)
    }
}
