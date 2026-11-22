import AppKit
import Foundation

extension AppState {
    var wallpaperUseZoomedDisplay: Bool {
        get { config.bool(forKey: "wallpaper_use_zoomed_display", default: false) }
        set {
            config.updateSetting("wallpaper_use_zoomed_display", value: newValue)
            menuCommandsRevision += 1
        }
    }

    /// One-time migration from legacy `current_display` fit mode (Python menu init).
    func migrateWallpaperSettingsIfNeeded() {
        let raw = config.string(forKey: "last_used_wallpaper_fit_method", default: "contain")
        guard raw == "current_display" else { return }
        config.updateSetting("last_used_wallpaper_fit_method", value: WallpaperManager.FitMethod.cover.configValue)
        config.updateSetting("wallpaper_use_zoomed_display", value: true)
    }

    private func wallpaperTargetScreenSize() -> (width: CGFloat, height: CGFloat)? {
        let screen = browseImageHost?.window?.screen ?? NSScreen.main
        guard let screen else { return nil }
        let frame = screen.frame
        return (frame.width, frame.height)
    }

    func browseViewportMatchesWallpaperScreenAspect() -> Bool {
        guard let host = browseImageHost, let screen = wallpaperTargetScreenSize() else { return false }
        return host.browseViewportMatchesScreenAspect(
            screenWidth: screen.width,
            screenHeight: screen.height
        )
    }

    func resolveWallpaperSource(explicitPath: String? = nil) -> (path: String?, tempToDelete: String?) {
        let currentPath = fileData.currentImagePath
        let zoomAppliesToPath = pathsMatchForWallpaper(explicitPath, currentPath)

        if fileData.currentViewMode == .browse,
           zoomAppliesToPath,
           let host = browseImageHost,
           host.hasLoadedImageForWallpaper == true
        {
            host.layoutSubtreeIfNeeded()
            if let temp = host.exportWallpaperHighResolutionCrop(tempDirectory: config.temporaryFilesDirectory) {
                return (temp, temp)
            }
            status.show("Wallpaper: could not derive crop from browse view — using full image file")
        }

        let path = explicitPath ?? currentPath ?? pathsForCopyPathCommand().first
        return (path, nil)
    }

    private func pathsMatchForWallpaper(_ a: String?, _ b: String?) -> Bool {
        if a == nil { return true }
        guard let a, let b else { return false }
        return URL(fileURLWithPath: a).standardizedFileURL.path
            == URL(fileURLWithPath: b).standardizedFileURL.path
    }

    func setCurrentImageAsDesktopBackground(
        fitMethod: WallpaperManager.FitMethod? = nil,
        explicitPath: String? = nil,
        persistFitMethod: Bool = false
    ) {
        let method = fitMethod ?? WallpaperManager.FitMethod(
            configValue: config.string(forKey: "last_used_wallpaper_fit_method", default: "contain")
        )

        let (imagePath, tempPath) = resolveWallpaperSource(explicitPath: explicitPath)
        defer {
            if let tempPath {
                try? FileManager.default.removeItem(atPath: tempPath)
            }
        }

        guard let imagePath else {
            status.show("No current image available")
            return
        }

        do {
            try wallpaperManager.setImageAsDesktopBackground(imagePath: imagePath, fitMethod: method)
            if persistFitMethod || fitMethod != nil {
                config.updateSetting("last_used_wallpaper_fit_method", value: method.configValue)
            }
            menuCommandsRevision += 1
            refreshMenuState()
        } catch {
            StyledMessageDialog.showWarning(
                title: "Cannot Set Wallpaper",
                message: error.localizedDescription
            )
        }
    }

    /// Port of `image_browser_window.resize_window_to_screen_aspect_ratio`.
    func resizeWindowToScreenAspectRatio() {
        let maxIters = 10
        let tolerance = 0.002

        if fileData.currentViewMode != .browse {
            StyledMessageDialog.showInformation(
                title: "Browse Mode",
                message: "Open an image in browse mode first (Space or F), then try again."
            )
            return
        }
        guard browseImageHost?.hasLoadedImageForWallpaper == true else {
            StyledMessageDialog.showInformation(title: "No Image", message: "Load an image first.")
            return
        }
        guard let window = browseImageHost?.window ?? WindowFullscreen.mainWindow() else { return }

        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            pumpLayoutEvents(for: window)
        }
        for _ in 0 ..< 4 {
            if !WindowFullscreen.isInMacOSSpace { break }
            window.toggleFullScreen(nil)
            pumpLayoutEvents(for: window)
        }

        guard let screen = window.screen ?? NSScreen.main else { return }
        let screenFrame = screen.frame
        let screenRatio = screenFrame.width / max(1, screenFrame.height)
        let available = screen.visibleFrame

        for _ in 0 ..< maxIters {
            pumpLayoutEvents(for: window)
            guard let host = browseImageHost else { return }
            let cw = max(1, host.bounds.width)
            let ch = max(1, host.bounds.height)
            let ratio = cw / ch
            if abs(ratio - screenRatio) < tolerance {
                status.show("Image area matches screen aspect ratio")
                DispatchQueue.main.async { [self] in focusMainCanvas() }
                return
            }
            let area = max(1, cw * ch)
            let targetW = round(sqrt(area * screenRatio))
            let targetH = round(targetW / screenRatio)
            let dw = Int(targetW) - Int(cw)
            let dh = Int(targetH) - Int(ch)
            if abs(dw) < 1, abs(dh) < 1 { break }

            var frame = window.frame
            frame.size.width += CGFloat(dw)
            frame.size.height += CGFloat(dh)
            frame.size.width = max(window.minSize.width, min(frame.size.width, available.width))
            frame.size.height = max(window.minSize.height, min(frame.size.height, available.height))
            window.setFrame(frame, display: true)
            pumpLayoutEvents(for: window)

            var origin = window.frame.origin
            let frameRect = window.frame
            if origin.x + frameRect.width > available.maxX {
                origin.x = available.maxX - frameRect.width
            }
            if origin.y + frameRect.height > available.maxY {
                origin.y = available.maxY - frameRect.height
            }
            if origin.x < available.minX { origin.x = available.minX }
            if origin.y < available.minY { origin.y = available.minY }
            if origin != window.frame.origin {
                window.setFrameOrigin(origin)
                pumpLayoutEvents(for: window)
            }
        }

        pumpLayoutEvents(for: window)
        if let host = browseImageHost {
            let cw = max(1, host.bounds.width)
            let ch = max(1, host.bounds.height)
            if abs(cw / ch - screenRatio) < tolerance {
                status.show("Image area matches screen aspect ratio")
            } else {
                status.show(
                    "Resize stopped after adjustments; image area may still differ slightly from screen aspect."
                )
            }
        }
        DispatchQueue.main.async { [self] in focusMainCanvas() }
    }

    private func pumpLayoutEvents(for window: NSWindow?) {
        window?.layoutIfNeeded()
        browseImageHost?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
}