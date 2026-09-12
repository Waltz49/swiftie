import AppKit

/// Control-click / right-click menu on thumbnail grid entries. Port of `thumbnail_context_menu.py`.
@MainActor
enum ThumbnailContextMenu {
    static func show(for event: NSEvent, clickedIndex: Int, in view: NSView, appState: AppState) {
        guard clickedIndex >= 0, clickedIndex < appState.fileData.displayedImages.count else { return }

        let clickedPath = appState.fileData.displayedImages[clickedIndex]
        guard FileManager.default.fileExists(atPath: clickedPath) else { return }

        let selected = appState.selection.selectedFiles
        let multiSelect = selected.count > 1
        if multiSelect, !selected.contains(clickedPath) {
            appState.status.show("Context menu request ignored.\nImage is not part of multiple selection.")
            return
        }

        if !multiSelect {
            appState.fileData.setCurrentIndex(clickedIndex)
            appState.fileData.setCurrentImagePath(clickedPath)
            appState.selection.selectedFiles = [clickedPath]
            appState.selection.emitSelectionChanged(highlightIndex: clickedIndex)
        }

        let paths = multiSelect ? selected.sorted() : [clickedPath]
        let singleOnly = paths.count == 1
        let inThumbnail = appState.fileData.currentViewMode == .thumbnail
        let confirmDelete = appState.config.bool(forKey: "confirm_delete", default: true)

        let menu = NSMenu()
        menu.autoenablesItems = false

        let rename = menu.addItem(
            withTitle: "Rename",
            action: #selector(MenuActions.rename(_:)),
            keyEquivalent: ""
        )
        NSMenuShortcutSupport.apply(display: "F2", to: rename)
        rename.target = MenuActions.shared
        rename.representedObject = paths
        rename.isEnabled = inThumbnail && singleOnly

        let deleteTitle = confirmDelete ? "Delete…" : "Delete"
        let delete = menu.addItem(
            withTitle: deleteTitle,
            action: #selector(MenuActions.deleteFiles(_:)),
            keyEquivalent: ""
        )
        delete.target = MenuActions.shared
        delete.representedObject = paths

        let copyPath = menu.addItem(
            withTitle: "Copy Pathname",
            action: #selector(MenuActions.copyPath(_:)),
            keyEquivalent: ""
        )
        NSMenuShortcutSupport.apply(display: "⌘C", to: copyPath)
        copyPath.target = MenuActions.shared
        copyPath.representedObject = paths

        let copyImage = menu.addItem(
            withTitle: "Copy image",
            action: #selector(MenuActions.copyImage(_:)),
            keyEquivalent: ""
        )
        NSMenuShortcutSupport.apply(display: "⌃C", to: copyImage)
        copyImage.target = MenuActions.shared
        copyImage.representedObject = paths
        copyImage.isEnabled = singleOnly

        let duplicate = menu.addItem(
            withTitle: "Duplicate",
            action: #selector(MenuActions.duplicateFiles(_:)),
            keyEquivalent: ""
        )
        duplicate.target = MenuActions.shared
        duplicate.representedObject = paths

        let findSimilar = menu.addItem(
            withTitle: "Find Similar Images…",
            action: #selector(MenuActions.findSimilar(_:)),
            keyEquivalent: ""
        )
        NSMenuShortcutSupport.apply(display: "⌘K", to: findSimilar)
        findSimilar.target = MenuActions.shared
        findSimilar.representedObject = paths

        let showInDirectory = menu.addItem(
            withTitle: "Show in Directory",
            action: #selector(MenuActions.showInDirectory(_:)),
            keyEquivalent: ""
        )
        NSMenuShortcutSupport.apply(display: "⇧⌘H", to: showInDirectory)
        showInDirectory.target = MenuActions.shared
        showInDirectory.representedObject = paths
        showInDirectory.isEnabled = singleOnly && appState.specificFilesActive

        let convertFormat = menu.addItem(
            withTitle: "Convert Format…",
            action: #selector(MenuActions.convertFormat(_:)),
            keyEquivalent: ""
        )
        NSMenuShortcutSupport.apply(display: "⌘M", to: convertFormat)
        convertFormat.target = MenuActions.shared
        convertFormat.representedObject = paths

        let resizeImages = menu.addItem(
            withTitle: "Resize…",
            action: #selector(MenuActions.resizeImages(_:)),
            keyEquivalent: ""
        )
        NSMenuShortcutSupport.apply(display: "⌘⇧Z", to: resizeImages)
        resizeImages.target = MenuActions.shared
        resizeImages.representedObject = paths

        menu.addItem(.separator())

        let editorName = appState.config.string(forKey: "image_editor_app", default: "Preview")
        let edit = menu.addItem(
            withTitle: "Edit in \(editorName)",
            action: #selector(MenuActions.editExternal(_:)),
            keyEquivalent: ""
        )
        NSMenuShortcutSupport.apply(display: "⌘E", to: edit)
        edit.target = MenuActions.shared
        edit.representedObject = paths
        edit.isEnabled = singleOnly || paths.count > 1

        let exif = menu.addItem(
            withTitle: "Edit EXIF User Comment…",
            action: #selector(MenuActions.editExifComment(_:)),
            keyEquivalent: ""
        )
        NSMenuShortcutSupport.apply(display: "⇧⌘E", to: exif)
        exif.target = MenuActions.shared
        exif.representedObject = paths

        let findRefs = menu.addItem(
            withTitle: "Find References to This Image…",
            action: #selector(MenuActions.findReferences(_:)),
            keyEquivalent: ""
        )
        findRefs.target = MenuActions.shared
        findRefs.representedObject = paths
        findRefs.isEnabled = singleOnly

        if singleOnly {
            let refGraph = menu.addItem(
                withTitle: "Show Reference Graph",
                action: #selector(MenuActions.showReferenceGraph(_:)),
                keyEquivalent: ""
            )
            refGraph.target = MenuActions.shared
            refGraph.representedObject = paths
        }

        if BundleCapabilities.facesUIEnabled, singleOnly {
            let faces = menu.addItem(
                withTitle: "Extract Faces",
                action: #selector(MenuActions.extractFaces(_:)),
                keyEquivalent: ""
            )
            NSMenuShortcutSupport.apply(display: "⇧⌘P", to: faces)
            faces.target = MenuActions.shared
            faces.representedObject = paths
        }

        let anyHasGPS = paths.contains { ExifService.gpsCoordinates(for: $0) != nil }
        let mapLocation = menu.addItem(
            withTitle: "Show Location on Map",
            action: #selector(MenuActions.showLocationOnMap(_:)),
            keyEquivalent: ""
        )
        NSMenuShortcutSupport.apply(display: "⌘G", to: mapLocation)
        mapLocation.target = MenuActions.shared
        mapLocation.representedObject = paths
        mapLocation.isEnabled = anyHasGPS

        menu.addItem(.separator())

        let reveal = menu.addItem(
            withTitle: "Open in Finder",
            action: #selector(MenuActions.revealInFinder(_:)),
            keyEquivalent: ""
        )
        reveal.target = MenuActions.shared
        reveal.representedObject = paths
        reveal.isEnabled = singleOnly

        if singleOnly {
            let wallpaperMenu = NSMenu()
            let contain = wallpaperMenu.addItem(
                withTitle: "Fit (Contain)",
                action: #selector(MenuActions.wallpaperContain(_:)),
                keyEquivalent: ""
            )
            contain.target = MenuActions.shared
            contain.representedObject = paths

            let cover = wallpaperMenu.addItem(
                withTitle: "Fill (Cover)",
                action: #selector(MenuActions.wallpaperCover(_:)),
                keyEquivalent: ""
            )
            cover.target = MenuActions.shared
            cover.representedObject = paths

            let width = wallpaperMenu.addItem(
                withTitle: "Fit to Width",
                action: #selector(MenuActions.wallpaperWidth(_:)),
                keyEquivalent: ""
            )
            width.target = MenuActions.shared
            width.representedObject = paths

            let height = wallpaperMenu.addItem(
                withTitle: "Fit to Height",
                action: #selector(MenuActions.wallpaperHeight(_:)),
                keyEquivalent: ""
            )
            height.target = MenuActions.shared
            height.representedObject = paths

            let wallpaperItem = NSMenuItem(title: "Set as Wallpaper", action: nil, keyEquivalent: "")
            wallpaperItem.submenu = wallpaperMenu
            menu.addItem(wallpaperItem)
        } else {
            let wallpaperDisabled = menu.addItem(withTitle: "Set as Wallpaper", action: nil, keyEquivalent: "")
            wallpaperDisabled.isEnabled = false
        }

        if multiSelect {
            menu.addItem(.separator())
            let note = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            note.isEnabled = false
            let noteView = NSTextField(labelWithString: "Some Items Disabled Due to\nMultiple Selection")
            noteView.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            noteView.textColor = .secondaryLabelColor
            noteView.alignment = .left
            noteView.frame = NSRect(x: 0, y: 0, width: 220, height: 32)
            note.view = noteView
            menu.addItem(note)
        }

        stripMenuIcons(menu)

        MenuActions.shared.appState = appState
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private static func stripMenuIcons(_ menu: NSMenu) {
        for item in menu.items {
            item.image = nil
            item.onStateImage = nil
            if let submenu = item.submenu {
                stripMenuIcons(submenu)
            }
        }
    }
}

@MainActor
private final class MenuActions: NSObject {
    static let shared = MenuActions()
    weak var appState: AppState?

    @objc func rename(_ sender: NSMenuItem) {
        guard let appState, let paths = sender.representedObject as? [String], let path = paths.first else { return }
        appState.beginRename(path: path)
    }

    @objc func deleteFiles(_ sender: NSMenuItem) {
        guard let appState, let paths = sender.representedObject as? [String] else { return }
        _ = appState.fileOperations.confirmAndMoveToTrash(paths)
    }

    @objc func copyPath(_ sender: NSMenuItem) {
        guard let appState, let paths = sender.representedObject as? [String] else { return }
        appState.fileOperations.copyPathsToClipboard(paths)
        appState.status.show(paths.count == 1 ? "Copied path" : "Copied \(paths.count) paths")
    }

    @objc func copyImage(_ sender: NSMenuItem) {
        guard let appState, let paths = sender.representedObject as? [String], let path = paths.first else { return }
        appState.fileOperations.copyImageToClipboard(path: path)
    }

    @objc func duplicateFiles(_ sender: NSMenuItem) {
        guard let appState, let paths = sender.representedObject as? [String] else { return }
        let created = appState.fileOperations.duplicateFiles(paths)
        if !created.isEmpty {
            appState.status.show("Duplicated \(created.count) file(s)")
        }
    }

    @objc func findSimilar(_ sender: NSMenuItem) {
        guard let appState else { return }
        appState.searchOperations.findSimilarImages()
    }

    @objc func convertFormat(_ sender: NSMenuItem) {
        guard let appState, let paths = sender.representedObject as? [String] else { return }
        appState.presentConvertFormatSheet(paths: paths)
    }

    @objc func resizeImages(_ sender: NSMenuItem) {
        guard let appState, let paths = sender.representedObject as? [String] else { return }
        appState.presentResizeSheet(paths: paths)
    }

    @objc func showInDirectory(_ sender: NSMenuItem) {
        guard let appState else { return }
        appState.showImageInDirectory()
    }

    @objc func showLocationOnMap(_ sender: NSMenuItem) {
        guard let appState else { return }
        appState.openMapForCurrentImage()
    }

    @objc func editExternal(_ sender: NSMenuItem) {
        guard let appState else { return }
        appState.fileOperations.openWithExternalEditor()
    }

    @objc func editExifComment(_ sender: NSMenuItem) {
        guard let appState, let paths = sender.representedObject as? [String], let path = paths.first else { return }
        appState.fileData.setCurrentImagePath(path)
        appState.exifOperations.editUserCommentForCurrent()
    }

    @objc func findReferences(_ sender: NSMenuItem) {
        guard let appState, let paths = sender.representedObject as? [String], let path = paths.first else { return }
        appState.findReferences(to: path)
    }

    @objc func showReferenceGraph(_ sender: NSMenuItem) {
        guard let appState, let paths = sender.representedObject as? [String], let path = paths.first else { return }
        appState.showReferenceGraph(for: path)
    }

    @objc func extractFaces(_ sender: NSMenuItem) {
        guard let appState, let paths = sender.representedObject as? [String], let path = paths.first else { return }
        KnownFacesService.openExtractFaces(appState: appState, imagePath: path)
    }

    @objc func revealInFinder(_ sender: NSMenuItem) {
        guard let appState, let paths = sender.representedObject as? [String] else { return }
        appState.fileOperations.revealInFinder(paths)
    }

    @objc func wallpaperContain(_ sender: NSMenuItem) { setWallpaper(sender, scaling: .contain) }
    @objc func wallpaperCover(_ sender: NSMenuItem) { setWallpaper(sender, scaling: .cover) }
    @objc func wallpaperWidth(_ sender: NSMenuItem) { setWallpaper(sender, scaling: .fitWidth) }
    @objc func wallpaperHeight(_ sender: NSMenuItem) { setWallpaper(sender, scaling: .fitHeight) }

    private func setWallpaper(_ sender: NSMenuItem, scaling: WallpaperService.Scaling) {
        guard let appState, let paths = sender.representedObject as? [String], let path = paths.first else { return }
        do {
            try WallpaperService.setWallpaper(path: path, scaling: scaling)
            appState.status.show("Wallpaper updated")
        } catch {
            appState.status.show("Wallpaper failed: \(error.localizedDescription)")
        }
    }
}
