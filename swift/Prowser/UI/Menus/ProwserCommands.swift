import Darwin
import SwiftUI
import AppKit

struct ProwserCommands: Commands {
    @Bindable var appState: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") {
                Task { @MainActor in openDirectory() }
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(after: .newItem) {
            Button("Back") {
                Task { @MainActor in appState.goBack() }
            }
            .keyboardShortcut("[", modifiers: .command)

            Button("Forward") {
                Task { @MainActor in appState.goForward() }
            }
            .keyboardShortcut("]", modifiers: .command)
        }

        CommandGroup(replacing: .undoRedo) {
            Button("Undo Delete") {
                Task { @MainActor in appState.fileOperations.undoLastFileOperation() }
            }
            .keyboardShortcut("z", modifiers: .command)
        }

        CommandMenu("Edit") {
            ExternalEditorButton(appState: appState)

            Divider()

            Button("Lock Files") {
                Task { @MainActor in appState.fileOperations.lockSelectedFiles() }
            }
            .keyboardShortcut("l", modifiers: .command)

            Button("Unlock Files") {
                Task { @MainActor in appState.fileOperations.unlockSelectedFiles() }
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Divider()

            Button("Copy Image") {
                Task { @MainActor in appState.fileOperations.copyImageToClipboard() }
            }
            .keyboardShortcut("c", modifiers: .command)

            Button("Copy Path") {
                Task { @MainActor in copyPath() }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Button("Select All") {
                Task { @MainActor in appState.fileOperations.selectAllDisplayed() }
            }
            .keyboardShortcut("a", modifiers: .command)

            Button("Deselect All") {
                Task { @MainActor in appState.fileOperations.deselectAll() }
            }
        }

        CommandMenu("File") {
            Menu("Recent…") {
                RecentDirectoriesMenuContent(appState: appState)
            }

            Menu("Favorites") {
                ForEach(1...9, id: \.self) { slot in
                    Button("Favorite \(slot)") {
                        Task { @MainActor in appState.fileOperations.openFavoriteDirectory(slot: slot) }
                    }
                }
            }

            Menu("Move to") {
                Button("Destination 1") { Task { @MainActor in appState.fileOperations.moveToDestination(slot: 1) } }
                Button("Destination 2") { Task { @MainActor in appState.fileOperations.moveToDestination(slot: 2) } }
                Button("Destination 3") { Task { @MainActor in appState.fileOperations.moveToDestination(slot: 3) } }
                Button("Destination 4") { Task { @MainActor in appState.fileOperations.moveToDestination(slot: 4) } }
                Button("Destination 5") { Task { @MainActor in appState.fileOperations.moveToDestination(slot: 5) } }
                Button("Destination 6") { Task { @MainActor in appState.fileOperations.moveToDestination(slot: 6) } }
                Button("Destination 7") { Task { @MainActor in appState.fileOperations.moveToDestination(slot: 7) } }
                Button("Destination 8") { Task { @MainActor in appState.fileOperations.moveToDestination(slot: 8) } }
                Button("Destination 9") { Task { @MainActor in appState.fileOperations.moveToDestination(slot: 9) } }
                Divider()
                Button("Last Drop Location") {
                    Task { @MainActor in appState.fileOperations.moveToLastDropLocation(copyOnly: false) }
                }
            }

            Divider()

            Button("Reveal in Finder") {
                Task { @MainActor in revealSelection() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Button("Move to Trash") {
                Task { @MainActor in deleteSelection() }
            }
            .keyboardShortcut(.delete, modifiers: .command)

            Button("Refresh") {
                Task { @MainActor in appState.refreshDirectory() }
            }
            .keyboardShortcut("r", modifiers: .command)

            Divider()

            Button("Close Window") {
                Task { @MainActor in NSApp.keyWindow?.close() }
            }
            .keyboardShortcut("w", modifiers: .command)

            Button("Quit Prowser") {
                Task { @MainActor in NSApp.terminate(nil) }
            }
            .keyboardShortcut("q", modifiers: .command)
        }

        CommandMenu("Image") {
            Button("Create an image from text…") {
                Task { @MainActor in openImageGenCreate() }
            }
            .disabled(!BundleCapabilities.imageGenUIEnabled)

            Divider()

            Button("Show Job Queue") {
                Task { @MainActor in appState.toggleJobsPanel() }
            }
            .keyboardShortcut("j", modifiers: .command)
            .disabled(!BundleCapabilities.imageGenUIEnabled)
        }

        CommandMenu("Search") {
            Button("Find Similar Image Files…") {
                Task { @MainActor in appState.searchOperations.findSimilarImages() }
            }
            .keyboardShortcut("k", modifiers: .command)

            Button("Search by Person…") {
                Task { @MainActor in appState.searchOperations.presentPersonSearch() }
            }
            .disabled(!BundleCapabilities.facesUIEnabled)

            Divider()

            Button("Find Duplicate Image Files in Directory") {
                Task { @MainActor in appState.searchOperations.findExactDuplicatesInDisplayed() }
            }

            Button("Find Duplicate Image Files (Recursive)") {
                Task { @MainActor in appState.searchOperations.findExactDuplicatesRecursive() }
            }
            .keyboardShortcut("f", modifiers: .shift)

            Divider()

            Button("Extract Faces") {
                Task { @MainActor in extractFaces() }
            }
            .disabled(!BundleCapabilities.facesUIEnabled)
        }

        CommandMenu("View") {
            Button("Thumbnails") {
                Task { @MainActor in appState.fileData.setViewMode(.thumbnail) }
            }
            .keyboardShortcut("1", modifiers: .command)
            Button("List") {
                Task { @MainActor in appState.fileData.setViewMode(.list) }
            }
            .keyboardShortcut("2", modifiers: .command)
            Button("Browse") {
                Task { @MainActor in appState.fileData.setViewMode(.browse) }
            }
            .keyboardShortcut("3", modifiers: .command)

            Divider()

            Button("Toggle File Tree") {
                Task { @MainActor in appState.toggleFileTree() }
            }
            .keyboardShortcut("t", modifiers: [])

            Button("Toggle Preview") {
                Task { @MainActor in appState.togglePreviewPane() }
            }
            .keyboardShortcut("p", modifiers: [])

            Button("Toggle Organize Sidebar") {
                Task { @MainActor in appState.toggleShortcutsSidebar() }
            }
            .keyboardShortcut("o", modifiers: [])

            Button("Toggle Information Sidebar") {
                Task { @MainActor in appState.toggleInformationSidebar() }
            }
            .keyboardShortcut("i", modifiers: [])

            Button("Toggle Jobs Pane") {
                Task { @MainActor in appState.toggleJobsPane() }
            }
            .keyboardShortcut("j", modifiers: [])
            .disabled(!BundleCapabilities.imageGenUIEnabled)

            Button("Toggle Status Bar") {
                Task { @MainActor in appState.toggleStatusBar() }
            }
            .keyboardShortcut("b", modifiers: [])

            Button("Show Chat") {
                Task { @MainActor in appState.toggleChatPane() }
            }
            .keyboardShortcut(",", modifiers: [])
            .disabled(!BundleCapabilities.chatUIEnabled)

            Divider()

            Menu("Sort By") {
                ForEach(SortMode.allCases, id: \.self) { mode in
                    Button(mode.displayName) {
                        Task { @MainActor in applySortMode(mode) }
                    }
                }
            }

            Button("Cycle Thumbnail Overlay") {
                Task { @MainActor in appState.cycleThumbnailOverlay() }
            }
            .keyboardShortcut("i", modifiers: .command)

            ActualSizeToggleButton(appState: appState)

            Divider()

            ChromeToggleMenuButton(appState: appState)

            FullscreenToggleButton()

            Divider()

            Button("Previous Image") {
                Task { @MainActor in navigate(.left) }
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Next Image") {
                Task { @MainActor in navigate(.right) }
            }
            .keyboardShortcut(.rightArrow, modifiers: [])

            Divider()

            Button("Dark Theme") {
                Task { @MainActor in applyTheme("dark") }
            }
            Button("Light Theme") {
                Task { @MainActor in applyTheme("light") }
            }
            Button("User Theme") {
                Task { @MainActor in applyTheme("user") }
            }
            Button("System Theme") {
                Task { @MainActor in applyTheme("system") }
            }
        }

        CommandMenu("Tools") {
            Menu("Slideshows") {
                Button("Multiple Images Slideshow") {
                    Task { @MainActor in appState.startSlideshow(.slideshow) }
                }
                .keyboardShortcut("s", modifiers: [])

                Button("Panning Slideshow") {
                    Task { @MainActor in appState.startSlideshow(.slideshow2) }
                }
                .keyboardShortcut("s", modifiers: .shift)

                Button("Floating Frames Slideshow") {
                    Task { @MainActor in appState.startSlideshow(.slideshow3) }
                }
                .keyboardShortcut("s", modifiers: [.shift, .control])
            }

            Divider()

            Menu("Create Screen Size Copy...") {
                Button("Create Screen Size Copy (Last Used)") {
                    Task { @MainActor in appState.createScreenSizeCopy() }
                }

                Divider()

                Button("Fit (Contain)") {
                    Task { @MainActor in appState.createScreenSizeCopy(fitMethod: .contain) }
                }
                Button("Fill (Cover)") {
                    Task { @MainActor in appState.createScreenSizeCopy(fitMethod: .cover) }
                }
                Button("Fit to Width") {
                    Task { @MainActor in appState.createScreenSizeCopy(fitMethod: .width) }
                }
                Button("Fit to Height") {
                    Task { @MainActor in appState.createScreenSizeCopy(fitMethod: .height) }
                }
            }

            Menu("Wallpaper") {
                Button("Set Wallpaper (Last Used)") {
                    Task { @MainActor in setWallpaperLastUsed() }
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])

                Divider()

                Button("Fit (Contain)") {
                    Task { @MainActor in setWallpaper(scaling: .contain, persist: true) }
                }
                Button("Fill (Cover)") {
                    Task { @MainActor in setWallpaper(scaling: .cover, persist: true) }
                }
                Button("Fit to Width") {
                    Task { @MainActor in setWallpaper(scaling: .fitWidth, persist: true) }
                }
                Button("Fit to Height") {
                    Task { @MainActor in setWallpaper(scaling: .fitHeight, persist: true) }
                }
            }

            Menu("Debug") {
                Button("Toggle Debug Mode") {
                    Task { @MainActor in toggleDebugMode() }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button("View Log") {
                    Task { @MainActor in openViewLog() }
                }
                .keyboardShortcut("d", modifiers: .control)

                Button("Toggle Number Overlay") {
                    Task { @MainActor in appState.toggleNumberOverlay() }
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }

            Divider()

            Menu("EXIF and Dates") {
                Button("Reset File Date to EXIF Timestamp…") {
                    Task { @MainActor in appState.exifOperations.resetFileDateToExifForSelection() }
                }
                Button("Reset EXIF Timestamp to File Date…") {
                    Task { @MainActor in appState.exifOperations.resetExifDateToFileDateForSelection() }
                }

                Divider()

                Button("Edit EXIF User Comment…") {
                    Task { @MainActor in appState.exifOperations.editUserCommentForCurrent() }
                }
                .keyboardShortcut("e", modifiers: [.control, .shift])

                Button("Delete User Comment from File…") {
                    Task { @MainActor in appState.exifOperations.deleteUserCommentForSelection() }
                }

                Divider()

                Button("Find References to This Image…") {
                    Task { @MainActor in
                        if let path = appState.fileData.currentImagePath {
                            appState.findReferences(to: path)
                        }
                    }
                }
            }
        }

        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") {
                Task { @MainActor in appState.showKeyboardHelp = true }
            }
            .keyboardShortcut("/", modifiers: [])

            Button("About Prowser") {
                Task { @MainActor in appState.showAbout = true }
            }
        }
    }

    @MainActor
    private func navigate(_ direction: ThumbnailNavigateDirection) {
        let images = appState.fileData.displayedImages
        guard !images.isEmpty else { return }
        KeyboardInputTracer.log(
            "ProwserCommands.navigate \(direction) view=\(appState.fileData.currentViewMode)",
            config: appState.config
        )

        switch appState.fileData.currentViewMode {
        case .thumbnail:
            appState.eventBus.emit(
                .thumbnailNavigate,
                payload: .thumbnailDirection(direction)
            )
        case .list:
            navigateList(direction)
        default:
            navigateLinear(direction)
        }
    }

    @MainActor
    private func navigateList(_ direction: ThumbnailNavigateDirection) {
        let images = appState.fileData.displayedImages
        let wrap = appState.config.bool(forKey: "wrap_around", default: true)
        let delta: Int
        switch direction {
        case .left, .up: delta = -1
        case .right, .down: delta = 1
        }
        let next = nextIndex(appState.fileData.currentIndex, delta: delta, count: images.count, wrap: wrap)
        appState.fileData.setCurrentIndex(next)
        appState.fileData.setCurrentImagePath(images[next])
    }

    @MainActor
    private func navigateLinear(_ direction: ThumbnailNavigateDirection) {
        let images = appState.fileData.displayedImages
        let wrap = appState.config.bool(forKey: "wrap_around", default: true)
        let delta = (direction == .left || direction == .up) ? -1 : 1
        let next = nextIndex(appState.fileData.currentIndex, delta: delta, count: images.count, wrap: wrap)
        appState.fileData.setCurrentIndex(next)
        appState.fileData.setCurrentImagePath(images[next])
    }

    @MainActor
    private func nextIndex(_ index: Int, delta: Int, count: Int, wrap: Bool) -> Int {
        guard count > 0 else { return 0 }
        let raw = index + delta
        if wrap {
            return ((raw % count) + count) % count
        }
        return min(max(0, raw), count - 1)
    }

    @MainActor
    private func openDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.loadDirectory(url.path)
    }

    @MainActor
    private func revealSelection() {
        let paths = selectedPaths()
        guard !paths.isEmpty else { return }
        appState.fileOperations.revealInFinder(paths)
    }

    @MainActor
    private func deleteSelection() {
        let paths = selectedPaths()
        guard !paths.isEmpty else { return }
        _ = appState.fileOperations.confirmAndMoveToTrash(paths)
    }

    @MainActor
    private func openImageGenCreate() {
        guard appState.imageGen.isEnabled else {
            let alert = NSAlert()
            alert.messageText = "Image generation unavailable"
            alert.informativeText = "Python workers are not available. Set PROWSER_PYTHON_ROOT or run from a full install."
            alert.runModal()
            return
        }
        appState.showImageGenCreateSheet = true
    }

    @MainActor
    private func applySortMode(_ mode: SortMode) {
        appState.config.updateSetting("sort_mode", value: mode.rawValue)
        appState.refreshDirectory()
    }

    @MainActor
    private func extractFaces() {
        guard let directory = appState.fileData.currentDirectory else { return }
        guard appState.workers.face.isAvailable else {
            let alert = NSAlert()
            alert.messageText = "Face extraction unavailable"
            alert.informativeText = "Python face worker is not available."
            alert.runModal()
            return
        }
        appState.workers.face.onFinished = { count in
            Task { @MainActor in appState.status.show("Face extraction complete (\(count) cached)") }
        }
        appState.workers.face.onError = { message in
            Task { @MainActor in appState.status.show(message) }
        }
        do {
            appState.status.show("Extracting faces…")
            try appState.workers.face.scanDirectory(directory, maxDepth: 99)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Face scan failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @MainActor
    private func setJobsVisible(_ visible: Bool) {
        appState.config.updateSetting("jobs_visible", value: visible)
        appState.config.applySettingsChange(emit: appState.eventBus)
    }

    @MainActor
    private func applyTheme(_ themeID: String) {
        appState.theme.setThemeID(themeID)
        appState.config.applySettingsChange(emit: appState.eventBus)
    }

    @MainActor
    private func copyPath() {
        let paths = selectedPaths()
        guard !paths.isEmpty else {
            appState.status.show("No files selected")
            return
        }
        appState.fileOperations.copyPathsToClipboard(paths)
        appState.status.show(paths.count == 1 ? "Copied path" : "Copied \(paths.count) paths")
    }

    @MainActor
    private func selectedPaths() -> [String] {
        if !appState.selection.selectedFiles.isEmpty {
            return Array(appState.selection.selectedFiles)
        }
        if let current = appState.fileData.currentImagePath {
            return [current]
        }
        return []
    }

    @MainActor
    private func wallpaperSourcePath() -> String? {
        if let current = appState.fileData.currentImagePath {
            return current
        }
        return selectedPaths().first
    }

    @MainActor
    private func setWallpaperLastUsed() {
        let method = appState.config.string(forKey: "last_used_wallpaper_fit_method", default: "contain")
        let scaling: WallpaperService.Scaling
        switch method {
        case "cover": scaling = .cover
        case "fitWidth": scaling = .fitWidth
        case "fitHeight": scaling = .fitHeight
        default: scaling = .contain
        }
        setWallpaper(scaling: scaling, persist: false)
    }

    @MainActor
    private func setWallpaper(scaling: WallpaperService.Scaling, persist: Bool) {
        guard let path = wallpaperSourcePath() else {
            appState.status.show("No image selected")
            return
        }
        do {
            try WallpaperService.setWallpaper(path: path, scaling: scaling)
            if persist {
                let key: String
                switch scaling {
                case .contain: key = "contain"
                case .cover: key = "cover"
                case .fitWidth: key = "fitWidth"
                case .fitHeight: key = "fitHeight"
                }
                appState.config.updateSetting("last_used_wallpaper_fit_method", value: key)
            }
            appState.status.show("Desktop wallpaper updated")
        } catch {
            let alert = NSAlert()
            alert.messageText = "Cannot Set Wallpaper"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @MainActor
    private func toggleDebugMode() {
        let enabled = !appState.config.bool(forKey: "debug_mode", default: false)
        appState.config.updateSetting("debug_mode", value: enabled)
        appState.status.show(enabled ? "Debug mode enabled" : "Debug mode disabled")
    }

    @MainActor
    private func openViewLog() {
        let logPath = appState.config.logsDirectory
            .appendingPathComponent("image_browser_print_\(getuid()).log")
        if FileManager.default.fileExists(atPath: logPath.path) {
            NSWorkspace.shared.open(logPath)
        } else {
            let alert = NSAlert()
            alert.messageText = "Log file not found"
            alert.informativeText = logPath.path
            alert.runModal()
        }
    }
}

private struct ActualSizeToggleButton: View {
    @Bindable var appState: AppState

    var body: some View {
        Button("Actual Size") {
            appState.toggleBrowseActualSize()
        }
        .keyboardShortcut("a", modifiers: [])
        .disabled(appState.fileData.currentViewMode != .browse)
    }
}

private struct ExternalEditorButton: View {
    @Bindable var appState: AppState

    var body: some View {
        Button("Edit with \(appState.config.string(forKey: "image_editor_app", default: "Preview"))") {
            appState.fileOperations.openWithExternalEditor()
        }
        .keyboardShortcut("e", modifiers: .control)
    }
}

private struct FullscreenToggleButton: View {
    @State private var inMacOSSpace = false

    var body: some View {
        Button(inMacOSSpace ? "Show in Windowed Mode" : "Show in macOS Space") {
            WindowFullscreen.toggleMacOSSpace()
            inMacOSSpace = WindowFullscreen.isInMacOSSpace
        }
        .keyboardShortcut("f", modifiers: [.command, .control])
        .onAppear {
            inMacOSSpace = WindowFullscreen.isInMacOSSpace
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            inMacOSSpace = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            inMacOSSpace = false
        }
    }
}

private struct ChromeToggleMenuButton: View {
    @Bindable var appState: AppState

    var body: some View {
        Button(appState.chromeToggleMenuTitle) {
            appState.toggleChrome()
        }
        .keyboardShortcut(".", modifiers: [])
        .keyboardShortcut(".", modifiers: .control)
    }
}

private struct RecentDirectoriesMenuContent: View {
    @Bindable var appState: AppState

    var body: some View {
        let recent = appState.config.recentDirectories()
        if recent.isEmpty {
            Button("No recent directories") {}
                .disabled(true)
        } else {
            ForEach(recent, id: \.self) { path in
                Button(Self.label(for: path)) {
                    appState.loadDirectory(path, saveHistory: true)
                }
            }
        }
    }

    private static func label(for path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix(NSHomeDirectory()) {
            return "~" + String(expanded.dropFirst(NSHomeDirectory().count))
        }
        return (expanded as NSString).lastPathComponent
    }
}
