import AppKit

/// macOS Space fullscreen helpers. Port of `browse_view_handler.enter_macos_space_mode`.
@MainActor
enum WindowFullscreen {
    /// User-facing Space mode (updated on enter; exit may be deferred — see `handleWillExitFullScreen`).
    private static var trackedMacOSSpaceMode = false
    private static var mainWindowClosing = false
    private static var applicationTerminating = false
    private static var deferredExitPersist: DispatchWorkItem?

    static func mainWindow() -> NSWindow? {
        NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible }
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

    static func applyLaunchPreference(noFullscreen: Bool, savedMacOSSpace: Bool?) {
        guard !noFullscreen else { return }
        let shouldFullscreen: Bool
        if let savedMacOSSpace {
            shouldFullscreen = savedMacOSSpace
        } else {
            shouldFullscreen = true
        }
        if shouldFullscreen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                enterMacOSSpace()
            }
        }
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
        ) { _ in
            MainActor.assumeIsolated {
                handleWillExitFullScreen(config: config)
            }
        }
    }

    static func handleWillEnterFullScreen(config: AppConfig) {
        cancelDeferredExitPersist()
        trackedMacOSSpaceMode = true
        config.updateRestoreMacOSSpaceMode(true)
    }

    /// Closing a Space window exits fullscreen before close; defer persisting windowed mode so quit restore stays correct.
    static func handleWillExitFullScreen(config: AppConfig) {
        cancelDeferredExitPersist()
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
        BrowserWindowIdentity.isMainBrowserWindow(window)
    }
}
