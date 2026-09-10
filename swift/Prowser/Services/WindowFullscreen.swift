import AppKit

/// macOS Space fullscreen helpers. Port of `browse_view_handler.enter_macos_space_mode`.
@MainActor
enum WindowFullscreen {
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

    static func applyLaunchPreference(noFullscreen: Bool, restoreState: Bool, savedMacOSSpace: Bool?) {
        guard !noFullscreen else { return }
        let shouldFullscreen: Bool
        if let savedMacOSSpace, restoreState {
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

    static func persistMacOSSpaceMode(config: AppConfig) {
        config.updateRestoreMacOSSpaceMode(isInMacOSSpace)
    }
}
