import Darwin
import SwiftUI
import AppKit

struct ProwserCommands: Commands {
    @Bindable var appState: AppState

    private var allowBrowserShortcuts: Bool {
        MainActor.assumeIsolated {
            appState.menuRefresh.browserWindowShortcutsEnabled
        }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) { }

        CommandGroup(replacing: .appInfo) {
            Button("About Prowser") {
                Task { @MainActor in appState.showAboutDialog() }
            }
        }

        // Python File → Exit uses QuitRole and `main_window.close`. Putting Quit in the
        // custom File menu steals ⌘Q from the app menu and does not close the window.
        CommandGroup(replacing: .appTermination) {
            Button("Quit Prowser") {
                Task { @MainActor in appState.closeMainWindow() }
            }
            .keyboardShortcut("q", modifiers: .command)
        }

        // Empty SwiftUI's auto View menu (toolbar) so it does not compete with our View menu.
        CommandGroup(replacing: .toolbar) {
            Divider()
        }

        CommandMenu(MenuBarTitles.edit) {
            Group {
                ExternalEditorButton(appState: appState)

                Divider()

                Button("Undo Delete") {
                    Task { @MainActor in appState.fileOperations.undoLastFileOperation() }
                }
                .keyboardShortcut("z", modifiers: .command)

                Divider()

                Button("Rename with Custom Prefix…") {
                    Task { @MainActor in appState.renameWithCustomPrefix() }
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Convert Image Format…") {
                    Task { @MainActor in appState.presentConvertFormatSheet() }
                }
                .keyboardShortcut("m", modifiers: .command)

                Button("Resize…") {
                    Task { @MainActor in appState.presentResizeSheet() }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])

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
                .keyboardShortcut("c", modifiers: .control)

                Button("Copy Path") {
                    Task { @MainActor in copyPath() }
                }
                .keyboardShortcut("c", modifiers: .command)

                Button("Select All") {
                    Task { @MainActor in appState.fileOperations.selectAllDisplayed() }
                }
                .keyboardShortcut("a", modifiers: .command)

                Button("Deselect All") {
                    Task { @MainActor in appState.fileOperations.deselectAll() }
                }
            }
            .disabled(!allowBrowserShortcuts)
        }

        CommandMenu(MenuBarTitles.file) {
            Group {
                Button("Open File…") {
                    Task { @MainActor in appState.openFileDialog() }
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("Open Directory…") {
                    Task { @MainActor in openDirectory() }
                }
                .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button("Back") {
                    Task { @MainActor in appState.goBack() }
                }
                .keyboardShortcut("[", modifiers: .command)

                Button("Forward") {
                    Task { @MainActor in appState.goForward() }
                }
                .keyboardShortcut("]", modifiers: .command)

                Divider()

                Menu("Recent…") {
                    RecentDirectoriesMenuContent(appState: appState)
                }

                Menu("Favorites") {
                    ForEach(1...9, id: \.self) { slot in
                        FavoriteMenuButton(appState: appState, slot: slot)
                    }
                }

                DestinationsMenuVisibility(appState: appState)

                Divider()

                Button("Settings…") {
                    Task { @MainActor in appState.openSettingsWindow() }
                }
                .keyboardShortcut(",", modifiers: .command)

                LastImageMenuButton(appState: appState)

                Button("Delete File") {
                    Task { @MainActor in deleteSelection() }
                }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])

                Button("Copy User Comment") {
                    Task { @MainActor in appState.copyUserCommentToClipboard() }
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

                TrashViewCopyMenuButton(appState: appState)

                Button("Image History") {
                    Task { @MainActor in appState.openBrowseImageHistory() }
                }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF3FunctionKey)!)), modifiers: [])

                Divider()
            }
            .disabled(!allowBrowserShortcuts)

            Button("Close Window") {
                Task { @MainActor in NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w", modifiers: .command)

            Divider()

            Button("About…") {
                Task { @MainActor in appState.showAboutDialog() }
            }
            .disabled(!allowBrowserShortcuts)
        }

        CommandMenu(MenuBarTitles.view) {
            Group {
                Button("Enter Image Viewer") {
                Task { @MainActor in
                    guard appState.fileData.currentImagePath != nil else { return }
                    appState.fileData.setViewMode(.browse)
                }
            }
            .keyboardShortcut("f", modifiers: [])

            Button("List View Toggle") {
                Task { @MainActor in appState.toggleListView() }
            }
            .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF12FunctionKey)!)), modifiers: [])

            Divider()

            PaneToggleButton(appState: appState, pane: .fileTree)
                .keyboardShortcut("t", modifiers: [])

            PaneToggleButton(appState: appState, pane: .preview)
                .keyboardShortcut("p", modifiers: [])

            PaneToggleButton(appState: appState, pane: .organizeSidebar)
                .keyboardShortcut("o", modifiers: [])

            PaneToggleButton(appState: appState, pane: .informationSidebar)
                .keyboardShortcut("i", modifiers: [])

            PaneToggleButton(appState: appState, pane: .statusBar)
                .keyboardShortcut("b", modifiers: [])

            Divider()

            Menu("Sort By") {
                SortMenuButton(appState: appState, title: "Date (Newest First)", mode: .date, reversed: false, apply: applySortMode)
                SortMenuButton(appState: appState, title: "Date (Oldest First)", mode: .date, reversed: true, apply: applySortMode)
                SortMenuButton(appState: appState, title: "EXIF Date (Newest First)", mode: .exifDate, reversed: false, apply: applySortMode)
                SortMenuButton(appState: appState, title: "EXIF Date (Oldest First)", mode: .exifDate, reversed: true, apply: applySortMode)
                SortMenuButton(appState: appState, title: "EXIF Year (Newest First)", mode: .exifYear, reversed: false, apply: applySortMode)
                SortMenuButton(appState: appState, title: "EXIF Year (Oldest First)", mode: .exifYear, reversed: true, apply: applySortMode)
                SortMenuButton(appState: appState, title: "Name (A-Z)", mode: .name, reversed: false, apply: applySortMode)
                SortMenuButton(appState: appState, title: "Name (Z-A)", mode: .name, reversed: true, apply: applySortMode)
                SortMenuButton(appState: appState, title: "Size (Largest First)", mode: .size, reversed: false, apply: applySortMode)
                SortMenuButton(appState: appState, title: "Size (Smallest First)", mode: .size, reversed: true, apply: applySortMode)
                Divider()
                Button("Reverse Sort Order") {
                    Task { @MainActor in appState.reverseSortOrder() }
                }
                .keyboardShortcut("t", modifiers: .command)
                RandomSortMenuButton(appState: appState)
                SortMenuButton(appState: appState, title: "Custom Sort", mode: .custom, reversed: false, apply: applySortMode)
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
            Button("Next Image") {
                Task { @MainActor in navigate(.right) }
            }

            Divider()

            ThemeMenuContent(appState: appState, applyTheme: applyTheme)
            }
            .disabled(!allowBrowserShortcuts)
        }

        CommandMenu("Search") {
            Group {
                Button("Search for Similar Images…") {
                    Task { @MainActor in appState.searchOperations.presentSimilaritySearchDialog() }
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("Search by Text…") {
                    Task { @MainActor in appState.searchOperations.presentClipSearchDialog() }
                }
                .keyboardShortcut("f", modifiers: .command)

                if FaceRecognitionCapabilities.facesUIEnabled(launchOptions: appState.launchOptions) {
                    Button("Search by Person…") {
                        Task { @MainActor in appState.searchOperations.presentPersonSearchDialog() }
                    }
                    .keyboardShortcut("p", modifiers: .command)

                    Button("Quick Person Search") {
                        Task { @MainActor in appState.searchOperations.runQuickPersonSearch() }
                    }
                    .keyboardShortcut("p", modifiers: [.command, .control])

                    Button("Extract Faces") {
                        Task { @MainActor in appState.searchOperations.extractFaces() }
                    }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                }

                Divider()

                Menu("Find Similar Image Files") {
                    Button("Find in This Directory") {
                        Task { @MainActor in appState.searchOperations.findSimilarImageFilesInDisplayed() }
                    }
                    Button("Find in This and Subdirectories") {
                        Task { @MainActor in appState.searchOperations.findSimilarImageFilesRecursive() }
                    }
                }

                Divider()

                Button("Find Duplicate Image Files in Directory") {
                    Task { @MainActor in appState.searchOperations.findExactDuplicatesInDisplayed() }
                }

                Button("Find Duplicate Image Files (Recursive)") {
                    Task { @MainActor in appState.searchOperations.findExactDuplicatesRecursive() }
                }

                Button("Show Image in Directory") {
                    Task { @MainActor in appState.showImageInDirectory() }
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            }
            .disabled(!allowBrowserShortcuts)
        }

        CommandMenu("Tools") {
            Group {
                Button("Quick Mass Rename…") {
                Task { @MainActor in appState.quickMassRename() }
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])

            Button("Backup Custom Sort") {
                Task { @MainActor in appState.backupCustomSort() }
            }

            Button("Restore Custom Sort") {
                Task { @MainActor in appState.restoreCustomSort() }
            }

            Button("Lock Selected File") {
                Task { @MainActor in appState.fileOperations.lockSelectedFiles() }
            }
            .keyboardShortcut("l", modifiers: .command)

            Button("Unlock Selected File") {
                Task { @MainActor in appState.fileOperations.unlockSelectedFiles() }
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Divider()

            MapLocationButton(appState: appState)

            Divider()

            Button("Open Home Directory") {
                Task { @MainActor in appState.openHomeDirectory() }
            }
            .keyboardShortcut("h", modifiers: .control)

            Button("Cache Subdirectories' Thumbnails") {
                Task { @MainActor in appState.prepopulateSubdirectoryThumbnails() }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])

            if FaceRecognitionCapabilities.facesUIEnabled(launchOptions: appState.launchOptions) {
                Button("Cache Subdirectories' Faces") {
                    Task { @MainActor in appState.searchOperations.cacheFaces() }
                }
                .keyboardShortcut("=", modifiers: .command)
            }

            DeleteExifDateMenuButton(appState: appState)

            Divider()

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
                Button("Print Cache Status") {
                    Task { @MainActor in appState.printCacheStatus() }
                }
                .keyboardShortcut("d", modifiers: .command)

                Button("Random Images") {
                    Task { @MainActor in appState.loadRandomImagesFromRecents() }
                }

                Button("View Live Log") {
                    Task { @MainActor in appState.openLiveLog() }
                }
                .keyboardShortcut("l", modifiers: .control)

                Divider()

                Button("Toggle Debug Mode") {
                    Task { @MainActor in appState.toggleDebugMode() }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button("Toggle Number Overlay") {
                    Task { @MainActor in appState.toggleNumberOverlay() }
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                if FaceRecognitionCapabilities.facesUIEnabled(launchOptions: appState.launchOptions) {
                    Button("Remove Facial Rec Models") {
                        Task { @MainActor in appState.removeFacialRecognitionModels() }
                    }
                }
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
                    Task { @MainActor in appState.beginEditUserComment() }
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

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
            .disabled(!allowBrowserShortcuts)
        }

        CommandGroup(replacing: .help) {
            Group {
                Button("Keyboard Shortcuts") {
                    Task { @MainActor in appState.showKeyboardHelp = true }
                }
                .keyboardShortcut("/", modifiers: [])

                Button("About Prowser") {
                    Task { @MainActor in appState.showAboutDialog() }
                }

                Button("Image Search (Native)…") {
                    Task { @MainActor in
                        appState.showImageRecognitionCaveats = true
                        appState.syncAuxiliaryDialogs()
                    }
                }
            }
            .disabled(!allowBrowserShortcuts)
        }
    }

    @MainActor
    private func navigate(_ direction: ThumbnailNavigateDirection) {
        if !appState.menuRefresh.browserWindowShortcutsEnabled {
            return
        }
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
        appState.fileOperations.deleteSelectedFiles()
    }

    @MainActor
    private func applySortMode(_ mode: SortMode, reversed: Bool = false) {
        appState.applySortMode(mode, reversed: reversed)
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
            StyledMessageDialog.showWarning(
                title: "Cannot Set Wallpaper",
                message: error.localizedDescription
            )
        }
    }

}

private struct MapLocationButton: View {
    @Bindable var appState: AppState

    var body: some View {
        Button("Show GPS Location on Map") {
            appState.openMapForCurrentImage()
        }
        .keyboardShortcut("g", modifiers: .command)
        .disabled(appState.fileData.currentViewMode != .thumbnail
            && appState.fileData.currentViewMode != .browse)
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
        .keyboardShortcut("e", modifiers: .command)
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
        Button(MenuStateHelpers.chromeToggleTitle(appState: appState)) {
            appState.toggleChrome()
        }
        .keyboardShortcut(".", modifiers: [])
        .keyboardShortcut(".", modifiers: .control)
    }
}

@MainActor
private struct DestinationsMenuVisibility: View {
    @Bindable var appState: AppState

    var body: some View {
        if appState.menuRefresh.destinationsMenuVisible {
            MoveDestinationsMenu(appState: appState)
        }
    }
}

@MainActor
private struct TrashViewCopyMenuButton: View {
    @Bindable var appState: AppState

    var body: some View {
        if appState.menuRefresh.canViewTrash {
            Button("View Copy of Trash…") {
                appState.browseTrashImages()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
        }
    }
}

@MainActor
private struct DeleteExifDateMenuButton: View {
    @Bindable var appState: AppState

    var body: some View {
        Button(appState.menuRefresh.deleteExifDateTitle) {
            appState.deleteExifDateFromSelection()
        }
        .disabled(!appState.menuRefresh.deleteExifDateEnabled)
    }
}

@MainActor
private struct MoveWorkFilesMenuButton: View {
    @Bindable var appState: AppState

    var body: some View {
        if appState.menuRefresh.moveWorkFilesVisible {
            Divider()
            Button("Move Work Files…") {
                appState.showMoveWorkFilesSheet = true
            }
        }
    }
}

private struct MoveDestinationsMenu: View {
    @Bindable var appState: AppState

    var body: some View {
        let action = appState.config.string(forKey: "destination_menu_action", default: "move")
        let title = action == "copy" ? "Copy to" : "Move to"
        Menu(title) {
            ForEach(1...9, id: \.self) { slot in
                DestinationMenuButton(appState: appState, slot: slot)
            }
            Divider()
            Button(MenuStateHelpers.lastDropDestinationMenuLabel(
                config: appState.config,
                lastDropLocation: appState.lastDropLocation
            )) {
                Task { @MainActor in
                    let copyOnly = appState.config.string(
                        forKey: "destination_menu_action",
                        default: "move"
                    ) == "copy"
                    appState.fileOperations.moveToLastDropLocation(copyOnly: copyOnly)
                }
            }
            MoveWorkFilesMenuButton(appState: appState)
            Divider()
            Button("Edit Destinations…") {
                Task { @MainActor in appState.openSettingsWindow(tab: .destinations) }
            }
        }
    }
}

private struct LastImageMenuButton: View {
    @Bindable var appState: AppState

    var body: some View {
        Button("Last Image") {
            Task { @MainActor in appState.swapBrowseImageHistoryFirstTwoAndShow() }
        }
        .keyboardShortcut(";", modifiers: .command)
        .disabled(appState.fileData.currentViewMode != .browse)
    }
}

private struct FavoriteMenuButton: View {
    @Bindable var appState: AppState
    let slot: Int

    var body: some View {
        Button(MenuStateHelpers.favoriteMenuLabel(slot: slot, config: appState.config)) {
            Task { @MainActor in appState.fileOperations.openFavoriteDirectory(slot: slot) }
        }
        .disabled(!MenuStateHelpers.favoriteIsEnabled(slot: slot, config: appState.config))
    }
}

private struct DestinationMenuButton: View {
    @Bindable var appState: AppState
    let slot: Int

    var body: some View {
        if MenuStateHelpers.destinationIsVisible(slot: slot, config: appState.config) {
            Button(MenuStateHelpers.destinationMenuLabel(
                slot: slot,
                config: appState.config,
                lastDropLocation: appState.lastDropLocation
            )) {
                Task { @MainActor in
                    let copyOnly = appState.config.string(forKey: "destination_menu_action", default: "move") == "copy"
                    appState.fileOperations.moveToDestination(slot: slot, copyOnly: copyOnly)
                }
            }
        }
    }
}

private struct SortMenuButton: View {
    @Bindable var appState: AppState
    let title: String
    let mode: SortMode
    let reversed: Bool
    let apply: @MainActor (SortMode, Bool) -> Void

    var body: some View {
        let checked = MenuStateHelpers.sortMenuItemChecked(mode: mode, reversed: reversed, config: appState.config)
        Button(checked ? "✓ \(title)" : title) {
            Task { @MainActor in apply(mode, reversed) }
        }
    }
}

private struct RandomSortMenuButton: View {
    @Bindable var appState: AppState

    var body: some View {
        let checked = MenuStateHelpers.sortMenuItemChecked(mode: .random, reversed: false, config: appState.config)
        Button(checked ? "✓ Random Sort" : "Random Sort") {
            Task { @MainActor in appState.applyRandomSort() }
        }
        .keyboardShortcut("r", modifiers: [])
    }
}

private enum PaneToggleKind {
    case fileTree
    case preview
    case organizeSidebar
    case informationSidebar
    case statusBar
}

@MainActor
private struct PaneToggleButton: View {
    @Bindable var appState: AppState
    let pane: PaneToggleKind

    var body: some View {
        let (name, visible) = paneLabelState
        Button(MenuStateHelpers.paneToggleLabel(name, visible: visible)) {
            Task { @MainActor in toggle() }
        }
    }

    @MainActor
    private var paneLabelState: (String, Bool) {
        switch pane {
        case .fileTree:
            return ("File Tree", appState.config.bool(forKey: "file_tree_visible", default: true))
        case .preview:
            return ("Preview", appState.config.bool(forKey: "preview_visible", default: true))
        case .organizeSidebar:
            return ("Organize Sidebar", appState.config.bool(forKey: "shortcuts_sidebar_visible", default: true))
        case .informationSidebar:
            return ("Information Sidebar", appState.config.bool(forKey: "information_sidebar_visible", default: true))
        case .statusBar:
            return ("Status Bar", appState.config.bool(forKey: "status_bar_visible", default: true))
        }
    }

    @MainActor
    private func toggle() {
        switch pane {
        case .fileTree: appState.toggleFileTree()
        case .preview: appState.togglePreviewPane()
        case .organizeSidebar: appState.toggleShortcutsSidebar()
        case .informationSidebar: appState.toggleInformationSidebar()
        case .statusBar: appState.toggleStatusBar()
        }
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

@MainActor
private struct ThemeMenuContent: View {
    @Bindable var appState: AppState
    let applyTheme: @MainActor (String) -> Void

    var body: some View {
        Menu("Theme") {
            Button("Dark") { applyTheme("dark") }
            Button("Light") { applyTheme("light") }
            Button("User") { applyTheme("user") }
            Button("Use System Setting") { applyTheme("system") }
            let customIDs = appState.theme.customThemeIDs
            if !customIDs.isEmpty {
                Divider()
                ForEach(customIDs, id: \.self) { themeID in
                    Button(appState.theme.customThemeDisplayName(themeID)) {
                        applyTheme(themeID)
                    }
                }
            }
        }
    }
}
