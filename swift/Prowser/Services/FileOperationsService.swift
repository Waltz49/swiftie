import AppKit
import Foundation

/// File move/delete/reveal operations. Port of `files/file_operations_manager.py` (phase 1).
@Observable
@MainActor
final class FileOperationsService {
    private weak var appState: AppState?
    let undoStack = FileUndoStack()

    func bind(_ appState: AppState) {
        self.appState = appState
    }

    var canUndoFileOperation: Bool { undoStack.canUndo }

    func revealInFinder(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func confirmAndMoveToTrash(_ paths: [String], forceConfirmation: Bool = false) -> [String] {
        guard !paths.isEmpty else { return [] }
        var remaining = paths
        if remaining.contains(where: RenamePrefixPlanner.isInsidePhotosLibrary) {
            showAlert("Operation Not Allowed", Self.photosLibraryDeleteMessage)
            remaining = remaining.filter { !RenamePrefixPlanner.isInsidePhotosLibrary($0) }
            if remaining.isEmpty { return [] }
        }
        let confirm = forceConfirmation || (appState?.config.bool(forKey: "confirm_delete", default: true) ?? true)
        if confirm, !confirmDelete(paths: remaining) {
            return []
        }
        return moveToTrash(remaining)
    }

    /// Delete current/selected files (⌘Delete). Port of `file_operations_manager.delete_selected_files`.
    func deleteSelectedFiles(forceConfirmation: Bool = false) {
        guard let appState else { return }
        var paths = selectedPaths(appState: appState)
        guard !paths.isEmpty else { return }

        let activePath = appState.fileData.currentImagePath
        if appState.fileData.currentViewMode == .browse, let activePath, !paths.contains(activePath) {
            paths = [activePath]
        }

        appState.selection.mostRecentSelectedPath = nil
        _ = confirmAndMoveToTrash(paths, forceConfirmation: forceConfirmation)
    }

    func moveToTrash(_ paths: [String]) -> [String] {
        guard let appState else { return [] }
        let originalDisplayed = appState.fileData.displayedImages
        let activePath = appState.fileData.currentImagePath
        var entries: [DeletedFileUndoEntry] = []
        var trashed: [String] = []
        var lockedNames: [String] = []

        for path in paths {
            if PrsortIO.isFileLocked(path) {
                lockedNames.append((path as NSString).lastPathComponent)
                continue
            }
            let url = URL(fileURLWithPath: path)
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = attrs?[.size] as? Int64
            let mtime = attrs?[.modificationDate] as? Date
            let inode = fileInode(at: path)
            let index = originalDisplayed.firstIndex(of: path)

            do {
                var trashURL: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &trashURL)
                let entry = DeletedFileUndoEntry(
                    originalPath: path,
                    trashPath: trashURL?.path,
                    originalIndex: index,
                    fileSize: size,
                    fileInode: inode,
                    modificationDate: mtime
                )
                entries.append(entry)
                trashed.append(path)
                backfillTrashPath(for: entry)
            } catch {
                NSLog("Failed to trash \(path): \(error)")
            }
        }

        if !lockedNames.isEmpty {
            let preview = lockedNames.prefix(5).joined(separator: "\n")
            let suffix = lockedNames.count > 5 ? "\n…and \(lockedNames.count - 5) more" : ""
            showAlert(
                "Cannot Delete Locked Files",
                "The following files are locked and were not deleted:\n\n\(preview)\(suffix)\n\nUnlock with ⇧⌘L first."
            )
        }

        if !entries.isEmpty {
            undoStack.pushDelete(entries)
        }
        if !trashed.isEmpty {
            appState.status.showFileOperation("Moved \(trashed.count) file(s) to Trash")
            DirectoryRefreshService.applyRemovedFiles(
                appState: appState,
                removed: Set(trashed),
                displayed: originalDisplayed,
                activePath: activePath
            )
            appState.selection.clearPreservingCurrentImage()
            appState.eventBus.emit(.fileOperationComplete)
            appState.refreshMenuState()
        }
        return trashed
    }

    func undoLastFileOperation() {
        guard let appState else { return }
        guard let operation = undoStack.pop() else {
            appState.status.showFileOperation("No undo operations available")
            return
        }
        switch operation {
        case .delete(let entries):
            restoreDeletedFiles(entries)
        case .move(let entries):
            restoreMovedFiles(entries)
        }
    }

    func lockSelectedFiles() {
        setLockState(locked: true)
    }

    func unlockSelectedFiles() {
        setLockState(locked: false)
    }

    func toggleLockSelectedFiles() {
        let paths = selectedPaths()
        guard !paths.isEmpty else {
            appState?.status.show("No files selected")
            return
        }
        let shouldLock = paths.contains { !PrsortIO.isFileLocked($0) }
        setLockState(locked: shouldLock, paths: paths)
    }

    func openWithExternalEditor() {
        guard let appState else { return }
        let paths = selectedPaths()
        guard let path = paths.first else {
            appState.status.show("No image selected")
            return
        }
        guard paths.count == 1 else {
            appState.status.show("Select a single image to edit")
            return
        }
        guard FileManager.default.fileExists(atPath: path) else {
            appState.status.show("File not found")
            return
        }

        let editorName = appState.config.string(forKey: "image_editor_app", default: "Preview")
        guard let appURL = Self.applicationURL(named: editorName) else {
            showAlert(
                "Editor Not Found",
                "Could not find application “\(editorName)” in /Applications or /System/Applications."
            )
            return
        }

        let fileURL = URL(fileURLWithPath: path)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: config) { _, error in
            Task { @MainActor in
                if let error {
                    appState.status.show("Could not open editor: \(error.localizedDescription)")
                }
            }
        }
    }

    func rename(path: String, to newName: String) throws -> String {
        let source = URL(fileURLWithPath: path)
        let dest = source.deletingLastPathComponent().appendingPathComponent(newName)
        try FileManager.default.moveItem(at: source, to: dest)
        let newPath = dest.path
        refreshAfterChange()
        return newPath
    }

    func copy(paths: [String], to directory: String) throws -> [String] {
        guard allowPhotosLibraryTransfer(paths: paths, targetDirectory: directory, copyOnly: true) else {
            return []
        }
        var copied: [String] = []
        let destDir = URL(fileURLWithPath: directory)
        for path in paths {
            let source = URL(fileURLWithPath: path)
            var dest = destDir.appendingPathComponent(source.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) {
                let base = source.deletingPathExtension().lastPathComponent
                let ext = source.pathExtension
                var counter = 1
                repeat {
                    let name = ext.isEmpty ? "\(base) copy \(counter)" : "\(base) copy \(counter).\(ext)"
                    dest = destDir.appendingPathComponent(name)
                    counter += 1
                } while FileManager.default.fileExists(atPath: dest.path)
            }
            try FileManager.default.copyItem(at: source, to: dest)
            copied.append(dest.path)
        }
        return copied
    }

    func move(paths: [String], to directory: String, refreshWhenDone: Bool = true) throws -> [String] {
        guard allowPhotosLibraryTransfer(paths: paths, targetDirectory: directory, copyOnly: false) else {
            return []
        }
        var blocked: [String] = []
        for path in paths where PrsortIO.isFileLocked(path) {
            blocked.append((path as NSString).lastPathComponent)
        }
        if !blocked.isEmpty {
            showAlert("Cannot Move Locked Files", "Unlock these files before moving:\n\n" + blocked.joined(separator: "\n"))
            return []
        }

        let displayed = appState?.fileData.displayedImages ?? []
        var moved: [String] = []
        var undoEntries: [MovedFileUndoEntry] = []
        let destDir = URL(fileURLWithPath: directory)
        for path in paths {
            let source = URL(fileURLWithPath: path)
            let dest = destDir.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: dest)
            moved.append(dest.path)
            undoEntries.append(
                MovedFileUndoEntry(
                    sourcePath: path,
                    targetPath: dest.path,
                    originalPosition: displayed.firstIndex(of: path)
                )
            )
        }
        if !undoEntries.isEmpty {
            undoStack.pushMove(undoEntries)
        }
        if refreshWhenDone {
            refreshAfterChange()
        }
        return moved
    }

    func moveToDestination(slot: Int, copyOnly: Bool? = nil) {
        guard let appState else { return }
        let paths = selectedPaths(appState: appState)
        guard !paths.isEmpty else {
            appState.status.show("No files selected")
            return
        }

        let destinations = appState.config.moveDestinations()
        guard slot >= 1, slot <= destinations.count else { return }
        guard let target = destinations[slot - 1]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !target.isEmpty else { return }

        let expanded = (target as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
            showAlert("Invalid Destination", "Destination \(slot) is not a valid folder:\n\(expanded)")
            return
        }

        let shouldCopy: Bool
        if let copyOnly {
            shouldCopy = copyOnly
        } else {
            let action = appState.config.string(forKey: "destination_menu_action", default: "move")
            if action == "none" { return }
            shouldCopy = action == "copy"
        }

        do {
            if shouldCopy {
                let copied = try copy(paths: paths, to: expanded)
                if !copied.isEmpty {
                    appState.status.show("Copied \(copied.count) file(s) to destination \(slot)")
                }
            } else {
                let moved = try move(paths: paths, to: expanded)
                if !moved.isEmpty {
                    appState.status.show("Moved \(moved.count) file(s) to destination \(slot)")
                }
            }
        } catch {
            appState.status.show("Operation failed: \(error.localizedDescription)")
        }
    }

    /// File-tree drop target. Port of `files/file_tree_handler.py` ``dropEvent``.
    @discardableResult
    func performFileTreeDrop(filePaths: [String], targetDirectory: String, operation: NSDragOperation) -> Bool {
        guard let appState else { return false }

        let files = filePaths.filter { path in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return false }
            return !isDir.boolValue
        }
        guard !files.isEmpty else { return false }

        let copyOnly = FileDragDropOperations.isCopyDrop(operation)
        guard allowPhotosLibraryTransfer(paths: files, targetDirectory: targetDirectory, copyOnly: copyOnly) else {
            return false
        }

        if !copyOnly {
            let targetReal = RenamePrefixPlanner.realPath(targetDirectory)
            var lockedNames: [String] = []
            for path in files {
                let sourceDir = RenamePrefixPlanner.realPath((path as NSString).deletingLastPathComponent)
                guard sourceDir != targetReal else { continue }
                if PrsortIO.isFileLocked(path) {
                    lockedNames.append((path as NSString).lastPathComponent)
                }
            }
            if !lockedNames.isEmpty {
                let preview = lockedNames.prefix(10).joined(separator: "\n")
                let suffix = lockedNames.count > 10 ? "\n... and \(lockedNames.count - 10) more" : ""
                showAlert(
                    "Cannot Move Locked Files",
                    """
                    The following files are locked and cannot be moved:

                    \(preview)\(suffix)

                    Please unlock the files (⇧⌘L) before moving them, or hold Option to copy instead.
                    """
                )
                return false
            }
        }

        appState.lastDropLocation = targetDirectory
        appState.refreshMenuState()

        do {
            if copyOnly {
                let copied = try copy(paths: files, to: targetDirectory)
                guard !copied.isEmpty else { return false }
                appState.config.debugLog(
                    "FileTree copy completed count=\(copied.count) dest=\(targetDirectory)"
                )
                appState.status.showFileOperation("Copied \(copied.count) file(s)")
                refreshDirectoryAfterTreeDrop(
                    appState: appState,
                    sourcePaths: files,
                    targetDirectory: targetDirectory,
                    copyOnly: true
                )
            } else {
                let displayed = appState.fileData.displayedImages
                let activePath = appState.fileData.currentImagePath
                let moved = try move(paths: files, to: targetDirectory, refreshWhenDone: false)
                guard !moved.isEmpty else { return false }
                appState.status.showFileOperation("Moved \(moved.count) file(s)")
                DirectoryRefreshService.applyRemovedFiles(
                    appState: appState,
                    removed: Set(files),
                    displayed: displayed,
                    activePath: activePath
                )
                for path in files {
                    appState.selection.selectedFiles.remove(path)
                }
                appState.selection.emitSelectionChanged(highlightIndex: appState.fileData.currentIndex)
                refreshDirectoryAfterTreeDrop(
                    appState: appState,
                    sourcePaths: files,
                    targetDirectory: targetDirectory,
                    copyOnly: false
                )
            }
            appState.fileTreeReloadToken += 1
            appState.eventBus.emit(.filesChangedOnDisk, payload: .string(targetDirectory))
            return true
        } catch {
            appState.status.show("Operation failed: \(error.localizedDescription)")
            return false
        }
    }

    private func refreshDirectoryAfterTreeDrop(
        appState: AppState,
        sourcePaths: [String],
        targetDirectory: String,
        copyOnly: Bool
    ) {
        guard let currentDirectory = appState.fileData.currentDirectory else { return }
        let currentNorm = FileDataModel.normalizePath(currentDirectory) ?? currentDirectory
        let targetNorm = FileDataModel.normalizePath(targetDirectory) ?? targetDirectory
        let sourcesFromCurrent = sourcePaths.contains { FileDataModel.pathIsInDirectory(file: $0, directory: currentNorm) }
        let targetIsCurrent = currentNorm == targetNorm
        if copyOnly {
            guard targetIsCurrent else { return }
        } else if !sourcesFromCurrent, !targetIsCurrent {
            return
        }
        appState.loadDirectory(currentDirectory, saveHistory: false)
    }

    func moveToLastDropLocation(copyOnly: Bool = false) {
        guard let appState else { return }
        guard let lastDrop = appState.lastDropLocation, !lastDrop.isEmpty else {
            appState.status.show("No last drop location")
            return
        }
        let paths = selectedPaths(appState: appState)
        guard !paths.isEmpty else {
            appState.status.show("No files selected")
            return
        }
        do {
            if copyOnly {
                let copied = try copy(paths: paths, to: lastDrop)
                if !copied.isEmpty {
                    appState.status.show("Copied to last drop location")
                }
            } else {
                let moved = try move(paths: paths, to: lastDrop)
                if !moved.isEmpty {
                    appState.status.show("Moved to last drop location")
                }
            }
        } catch {
            appState.status.show("Operation failed: \(error.localizedDescription)")
        }
    }

    func copyPathsToClipboard(_ paths: [String]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    func copyImageToClipboard(path explicitPath: String? = nil) {
        guard let appState else { return }
        let path = explicitPath ?? appState.fileData.currentImagePath
        guard let path, FileManager.default.fileExists(atPath: path) else {
            appState.status.show("No image to copy")
            return
        }
        guard let image = NSImage(contentsOfFile: path) else {
            appState.status.show("Could not load image for clipboard")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        let name = (path as NSString).lastPathComponent
        appState.status.show("Copied image to clipboard: \(name)")
    }

    func duplicateFiles(_ paths: [String]) -> [String] {
        var created: [String] = []
        for path in paths {
            guard let copyPath = duplicateFile(at: path) else { continue }
            created.append(copyPath)
        }
        if !created.isEmpty {
            refreshAfterChange()
        }
        return created
    }

    func beginRename(path: String) {
        guard let appState else { return }
        guard let newName = StyledMessageDialog.presentTextInput(
            title: "Rename",
            message: (path as NSString).lastPathComponent,
            initialText: (path as NSString).lastPathComponent,
            confirmTitle: "Rename"
        ), newName != (path as NSString).lastPathComponent else { return }

        do {
            let newPath = try rename(path: path, to: newName)
            appState.fileData.setCurrentImagePath(newPath)
            appState.status.show("Renamed to \(newName)")
        } catch {
            showAlert("Rename Failed", error.localizedDescription)
        }
    }

    private func duplicateFile(at path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let source = URL(fileURLWithPath: path)
        let directory = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension

        var candidate = directory.appendingPathComponent(
            ext.isEmpty ? "\(base)_copy" : "\(base)_copy.\(ext)"
        )
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(
                ext.isEmpty ? "\(base)_copy\(counter)" : "\(base)_copy\(counter).\(ext)"
            )
            counter += 1
        }
        do {
            try FileManager.default.copyItem(at: source, to: candidate)
            return candidate.path
        } catch {
            NSLog("Duplicate failed for \(path): \(error)")
            return nil
        }
    }

    func selectAllDisplayed() {
        guard let appState else { return }
        let images = appState.fileData.displayedImages
        guard !images.isEmpty else { return }
        appState.selection.selectedFiles = Set(images)
        appState.fileData.setCurrentIndex(0)
        appState.fileData.setCurrentImagePath(images[0])
        appState.selection.emitSelectionChanged(highlightIndex: 0)
    }

    func deselectAll() {
        guard let appState else { return }
        SelectionService.clearSelection(appState: appState)
    }

    func openFavoriteDirectory(slot: Int) {
        guard let appState, slot >= 1, slot <= 9 else { return }
        let favorites = appState.config.favoriteDirectories()
        guard let path = favorites[slot - 1]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return }
        let expanded = (path as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) else { return }

        if isDir.boolValue {
            appState.loadDirectory(expanded, saveHistory: true)
            appState.clearBrowseReturnState()
            if appState.fileData.currentViewMode != .thumbnail {
                appState.fileData.setViewMode(.thumbnail)
            }
        } else {
            let ext = URL(fileURLWithPath: expanded).pathExtension.lowercased()
            let allowed = Set(appState.config.imageExtensions.map { AppConfig.normalizeExtension($0) })
            guard allowed.contains(ext) else { return }
            appState.openPaths([expanded])
        }
    }

    private func restoreMovedFiles(_ entries: [MovedFileUndoEntry]) {
        guard let appState else { return }
        var restored = 0
        var errors: [String] = []

        for entry in entries {
            guard FileManager.default.fileExists(atPath: entry.targetPath) else {
                errors.append((entry.targetPath as NSString).lastPathComponent)
                continue
            }
            let sourceDir = (entry.sourcePath as NSString).deletingLastPathComponent
            guard FileManager.default.fileExists(atPath: sourceDir) else {
                errors.append((entry.sourcePath as NSString).lastPathComponent)
                continue
            }

            var restorePath = entry.sourcePath
            if FileManager.default.fileExists(atPath: restorePath) {
                let sourceURL = URL(fileURLWithPath: entry.sourcePath)
                let base = sourceURL.deletingPathExtension().lastPathComponent
                let ext = sourceURL.pathExtension
                var counter = 1
                repeat {
                    let name = ext.isEmpty ? "\(base)_restored_\(counter)" : "\(base)_restored_\(counter).\(ext)"
                    restorePath = sourceURL.deletingLastPathComponent().appendingPathComponent(name).path
                    counter += 1
                } while FileManager.default.fileExists(atPath: restorePath)
            }

            do {
                try FileManager.default.moveItem(
                    at: URL(fileURLWithPath: entry.targetPath),
                    to: URL(fileURLWithPath: restorePath)
                )
                restored += 1
                appState.metadataCache.invalidate(path: entry.targetPath)
                appState.metadataCache.invalidate(path: restorePath)
            } catch {
                errors.append((entry.targetPath as NSString).lastPathComponent)
            }
        }

        if restored > 0 {
            let suffix = errors.isEmpty ? "" : ", \(errors.count) error(s)"
            appState.status.showFileOperation("Undo: Moved \(restored) file(s) back\(suffix)")
            refreshAfterChange()
        } else {
            appState.status.showFileOperation("Could not undo move operation")
        }
    }

    private func restoreDeletedFiles(_ entries: [DeletedFileUndoEntry]) {
        guard let appState else { return }
        let ordered = entries.sorted {
            ($0.originalIndex ?? Int.max) < ($1.originalIndex ?? Int.max)
        }
        var restored = 0
        for entry in ordered {
            if TrashRestore.restore(entry: entry) != nil {
                restored += 1
            }
        }
        if restored > 0 {
            appState.clearDeletedPlaceholders(for: ordered.map(\.originalPath))
            appState.status.showFileOperation("Restored \(restored) file(s) from Trash")
            refreshAfterChange()
            appState.refreshMenuState()
        } else {
            appState.status.showFileOperation("Could not restore deleted files")
        }
    }

    private func backfillTrashPath(for entry: DeletedFileUndoEntry) {
        Task.detached(priority: .utility) {
            let located = TrashRestore.locateJustTrashed(entry: entry)
            guard let located else { return }
            await MainActor.run { [weak self] in
                self?.undoStack.backfillTrashPath(originalPath: entry.originalPath, trashPath: located)
            }
        }
    }

    private func confirmDelete(paths: [String]) -> Bool {
        let deleteSettingsNote = "Delete confirmations can be turned off in the Preferences' General tab (⌘,)"
        let message: String
        let secondaryMessage: String?
        if paths.count == 1 {
            let name = (paths[0] as NSString).lastPathComponent
            message = "Are you sure you want to delete this file?\n\n\(name)"
            secondaryMessage = deleteSettingsNote
        } else {
            message = "Are you sure you want to delete these \(paths.count) files?"
            secondaryMessage = deleteSettingsNote
        }
        return StyledMessageDialog.showConfirm(
            title: "Delete Files",
            message: message,
            secondaryMessage: secondaryMessage,
            confirmTitle: "Delete"
        )
    }

    private func fileInode(at path: String) -> UInt64? {
        var statBuf = stat()
        guard stat(path, &statBuf) == 0 else { return nil }
        return UInt64(statBuf.st_ino)
    }

    private func setLockState(locked: Bool, paths: [String]? = nil) {
        guard let appState else { return }
        let selected = paths ?? selectedPaths(appState: appState)
        guard !selected.isEmpty else {
            appState.status.show("No files selected")
            return
        }
        let directories = Set(selected.map { ($0 as NSString).deletingLastPathComponent })
        guard directories.count == 1, let directory = directories.first else {
            showAlert("Lock Files", "Select files from a single directory to lock or unlock.")
            return
        }

        var lockedSet = PrsortIO.lockedFilenames(in: directory)
        for path in selected {
            let name = (path as NSString).lastPathComponent
            if locked {
                lockedSet.insert(name)
            } else {
                lockedSet.remove(name)
            }
        }

        do {
            try PrsortIO.writeLocks(
                in: directory,
                displayedPaths: appState.fileData.displayedImages,
                lockedFilenames: lockedSet
            )
            appState.status.show(locked ? "Locked \(selected.count) file(s)" : "Unlocked \(selected.count) file(s)")
            refreshAfterChange()
        } catch {
            showAlert("Lock Failed", error.localizedDescription)
        }
    }

    private func selectedPaths(appState: AppState? = nil) -> [String] {
        let state = appState ?? self.appState
        guard let state else { return [] }
        if !state.selection.selectedFiles.isEmpty {
            return Array(state.selection.selectedFiles)
        }
        if let current = state.fileData.currentImagePath {
            return [current]
        }
        return []
    }

    private static func applicationURL(named name: String) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidates = [
            "/Applications/\(trimmed).app",
            "/System/Applications/\(trimmed).app",
            "~/Applications/\(trimmed).app",
        ]
        for candidate in candidates {
            let path = (candidate as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private static let photosLibraryDeleteMessage = """
        Deleting files from macOS Photos Library is not allowed.

        Photos Library files cannot be deleted or modified.
        """

    /// Photos Library: no add/delete/move of library files. Copying out is allowed.
    private func allowPhotosLibraryTransfer(
        paths: [String],
        targetDirectory: String,
        copyOnly: Bool
    ) -> Bool {
        let targetInLibrary = RenamePrefixPlanner.isInsidePhotosLibrary(targetDirectory)
        let hasLibrarySources = paths.contains(where: RenamePrefixPlanner.isInsidePhotosLibrary)

        if targetInLibrary {
            let message: String
            if hasLibrarySources {
                message = """
                    File operations within macOS Photos Library are not allowed.

                    Photos Library files cannot be moved, renamed, or modified within the library.
                    You can copy files OUT of the Photos Library to other locations.
                    """
            } else {
                message = """
                    Adding files to macOS Photos Library is not allowed.

                    Please use the Photos app to add files to your Photos Library.
                    """
            }
            appState?.config.debugLog(
                "Photos Library blocked \(hasLibrarySources ? "within-library" : "add") dest=\(targetDirectory)"
            )
            showAlert("Operation Not Allowed", message)
            return false
        }

        if hasLibrarySources && !copyOnly {
            appState?.config.debugLog("Photos Library blocked move from library dest=\(targetDirectory)")
            showAlert(
                "Operation Not Allowed",
                """
                Moving files from macOS Photos Library is not allowed.

                Photos Library files cannot be moved, renamed, or modified.
                You can copy files OUT of the Photos Library to other locations.
                """
            )
            return false
        }
        return true
    }

    private func showAlert(_ title: String, _ message: String) {
        StyledMessageDialog.showWarning(title: title, message: message)
    }

    private func refreshAfterChange() {
        guard let appState, let directory = appState.fileData.currentDirectory else { return }
        appState.loadDirectory(directory, saveHistory: false)
        appState.eventBus.emit(.filesChangedOnDisk, payload: .string(directory))
    }
}
