import AppKit

/// macOS Space fullscreen helpers. Port of `browse_view_handler.enter_macos_space_mode`.
@MainActor
enum WindowFullscreen {
    /// User-facing Space mode (updated on enter; exit may be deferred — see `handleWillExitFullScreen`).
    private static var trackedMacOSSpaceMode = false
    private static var mainWindowClosing = false
    private static var applicationTerminating = false
    private static var deferredExitPersist: DispatchWorkItem?
    private static var pendingLaunchShouldFullscreen: Bool?
    private static var launchFullscreenRetryGeneration = 0

    /// While launching Space mode — defer duplicate main-window teardown (`AppDelegate.closeDuplicateMainWindows`).
    static func isLaunchFullscreenSettling() -> Bool {
        pendingLaunchShouldFullscreen != nil
    }

    static func mainWindow() -> NSWindow? {
        if let tagged = BrowserWindowIdentity.resolveMainBrowserWindow() {
            return tagged
        }
        return NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible }
    }

    static var isInMacOSSpace: Bool {
        mainWindow()?.styleMask.contains(.fullScreen) ?? false
    }

    static func enterMacOSSpace() {
        guard let window = mainWindow() else { return }
        if !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    static func exitMacOSSpace() {
        guard let window = mainWindow() else { return }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    static func toggleMacOSSpace() {
        mainWindow()?.toggleFullScreen(nil)
    }

    static func applyLaunchPreference(
        forceFullscreen: Bool,
        noFullscreen: Bool,
        savedMacOSSpace: Bool?
    ) {
        let shouldFullscreen: Bool
        if forceFullscreen {
            shouldFullscreen = true
        } else if noFullscreen {
            shouldFullscreen = false
        } else if let savedMacOSSpace {
            shouldFullscreen = savedMacOSSpace
        } else {
            shouldFullscreen = true
        }
        pendingLaunchShouldFullscreen = shouldFullscreen
        launchFullscreenRetryGeneration += 1
        let generation = launchFullscreenRetryGeneration
        scheduleLaunchFullscreenRetries(generation: generation, forceOverride: forceFullscreen)
    }

    /// Apply CLI / saved Space preference once the tagged main browser window exists (Python backup timer).
    static func applyPendingLaunchFullscreenIfNeeded() {
        guard let shouldFullscreen = pendingLaunchShouldFullscreen else { return }
        guard let window = BrowserWindowIdentity.resolveMainBrowserWindow() else { return }
        let inSpace = window.styleMask.contains(.fullScreen)
        if shouldFullscreen == inSpace {
            if !shouldFullscreen {
                pendingLaunchShouldFullscreen = nil
            }
            return
        }
        guard window.isVisible else { return }
        window.toggleFullScreen(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let after = window.styleMask.contains(.fullScreen)
            if pendingLaunchShouldFullscreen == true, !after {
                applyPendingLaunchFullscreenIfNeeded()
            }
        }
    }

    private static func scheduleLaunchFullscreenRetries(generation: Int, forceOverride: Bool) {
        var delays: [TimeInterval] = [0, 0.15, 0.3, 0.6, 1.0]
        if forceOverride {
            delays.append(contentsOf: [1.5, 2.0])
        }
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard generation == launchFullscreenRetryGeneration else { return }
                applyPendingLaunchFullscreenIfNeeded()
            }
        }
    }

    private static func clearLaunchFullscreenPending() {
        pendingLaunchShouldFullscreen = nil
    }

    /// Value to store in `restore_state.last_macos_space_mode` on quit (Python `prowser.py` + `is_macos_space_mode`).
    static func macOSSpaceModeForRestore() -> Bool {
        if isInMacOSSpace {
            return true
        }
        if trackedMacOSSpaceMode, mainWindowClosing || applicationTerminating {
            return true
        }
        if NSApp.presentationOptions.contains(.fullScreen) {
            return true
        }
        return trackedMacOSSpaceMode
    }

    static func noteMainWindowClosing() {
        mainWindowClosing = true
        cancelDeferredExitPersist()
    }

    static func noteApplicationTerminating() {
        applicationTerminating = true
        cancelDeferredExitPersist()
    }

    static func installRestoreTracking(config: AppConfig) {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow, isMainBrowserWindow(window) else { return }
                noteMainWindowClosing()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.willEnterFullScreenNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                handleWillEnterFullScreen(config: config)
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.willExitFullScreenNotification,
            object: nil,
            queue: .main
        ) { note in
            MainActor.assumeIsolated {
                let window = note.object as? NSWindow
                handleWillExitFullScreen(config: config, window: window)
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification,
            object: nil,
            queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow else { return }
                handleDidEnterFullScreen(config: config, window: window)
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: nil,
            queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow else { return }
                handleDidExitFullScreen(config: config, window: window)
            }
        }
    }

    static func handleWillEnterFullScreen(config: AppConfig) {
        cancelDeferredExitPersist()
        trackedMacOSSpaceMode = true
        config.updateRestoreMacOSSpaceMode(true)
    }

    static func handleDidEnterFullScreen(config: AppConfig, window: NSWindow) {
        guard isMainBrowserWindow(window) || BrowserWindowIdentity.isTaggedMainBrowserWindow(window) else { return }
        if pendingLaunchShouldFullscreen == true {
            clearLaunchFullscreenPending()
        }
        cancelDeferredExitPersist()
        trackedMacOSSpaceMode = true
        config.updateRestoreMacOSSpaceMode(true)
    }

    static func handleDidExitFullScreen(config: AppConfig, window: NSWindow) {
        guard BrowserWindowIdentity.isTaggedMainBrowserWindow(window) else { return }
        if pendingLaunchShouldFullscreen == true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                applyPendingLaunchFullscreenIfNeeded()
            }
        }
    }

    /// Closing a Space window exits fullscreen before close; defer persisting windowed mode so quit restore stays correct.
    static func handleWillExitFullScreen(config: AppConfig, window: NSWindow?) {
        cancelDeferredExitPersist()
        if pendingLaunchShouldFullscreen == true,
           let window, BrowserWindowIdentity.isTaggedMainBrowserWindow(window) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                applyPendingLaunchFullscreenIfNeeded()
            }
            return
        }
        let work = DispatchWorkItem {
            guard !mainWindowClosing, !applicationTerminating else { return }
            trackedMacOSSpaceMode = false
            config.updateRestoreMacOSSpaceMode(false)
        }
        deferredExitPersist = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private static func cancelDeferredExitPersist() {
        deferredExitPersist?.cancel()
        deferredExitPersist = nil
    }

    private static func isMainBrowserWindow(_ window: NSWindow) -> Bool {
        BrowserWindowIdentity.isTaggedMainBrowserWindow(window)
    }
}
