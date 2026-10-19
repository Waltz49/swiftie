import AppKit
import Foundation

/// Result of a batch move/copy with per-file conflict resolution (Python `FileMoveHandler`).
struct FileBatchTransferOutcome {
    var transfers: [(source: String, target: String)] = []
    var undoEntries: [MovedFileUndoEntry] = []
    var successCount = 0
    var skippedCount = 0
    var userCancelled = false
    var failedFilenames: [String] = []
}

/// Result of inline rename commit (thumbnail or file tree).
enum InlineRenameOutcome {
    case unchanged
    case renamed(newPath: String, displayName: String)
    case keepEditing(message: String)
    case blocked(title: String, message: String)
}

/// File move/delete/reveal operations. Port of `files/file_operations_manager.py` (phase 1).
@Observable
@MainActor
final class FileOperationsService {
    private weak var appState: AppState?
    let undoStack = FileUndoStack()

    func bind(_ appState: AppState) {
        self.appState = appState
        ExternalEditorSession.shared.bind(appState: appState)
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
        guard let appState else { return }
        let paths = SelectionService.pathsForLockUnlock(appState: appState)
        guard !paths.isEmpty else {
            appState.status.show("No files selected")
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

        ExternalEditorSession.shared.beginEdit(path: path, editorName: editorName, editorURL: appURL)
    }

    func rename(path: String, to newName: String) throws -> String {
        let source = URL(fileURLWithPath: path)
        let dest = source.deletingLastPathComponent().appendingPathComponent(newName)
        try FileManager.default.moveItem(at: source, to: dest)
        let newPath = dest.path
        refreshAfterChange()
        return newPath
    }

    // MARK: - Inline rename (Python thumbnail_canvas / file_tree_handler)

    /// Port of `thumbnail_canvas._validate_macos_filename` (basename without extension).
    static func validateMacOSFilenameBase(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Filename cannot be empty" }
        for char in ["/", ":"] where trimmed.contains(char) {
            return "Filename cannot contain '\(char)'"
        }
        for scalar in trimmed.unicodeScalars where scalar.value < 0x20 && scalar.value != 0x09 && scalar.value != 0x0A {
            return "Filename contains invalid control characters"
        }
        return nil
    }

    /// Port of `file_tree_handler._validate_directory_name`.
    static func validateDirectoryName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Directory name cannot be empty" }
        for char in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"] where trimmed.contains(char) {
            return "Directory name cannot contain '\(char)'"
        }
        let reserved: Set<String> = [
            "CON", "PRN", "AUX", "NUL",
            "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
            "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
        ]
        if reserved.contains(trimmed.uppercased()) {
            return "'\(trimmed)' is a reserved name"
        }
        return nil
    }

    func commitFileRename(path: String, newBaseName: String) -> InlineRenameOutcome {
        let trimmed = newBaseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalBase = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        if trimmed == originalBase { return .unchanged }

        if RenamePrefixPlanner.isInsidePhotosLibrary(path) {
            return .blocked(
                title: "Operation Not Allowed",
                message: """
                    Renaming files within macOS Photos Library is not allowed.

                    Photos Library files cannot be renamed or modified.
                    """
            )
        }

        if let error = Self.validateMacOSFilenameBase(trimmed) {
            return .keepEditing(message: error)
        }

        let ext = (path as NSString).pathExtension
        let newFilename = ext.isEmpty ? trimmed : "\(trimmed).\(ext)"
        let directory = (path as NSString).deletingLastPathComponent
        let newPath = (directory as NSString).appendingPathComponent(newFilename)
        if FileManager.default.fileExists(atPath: newPath), newPath != path {
            return .keepEditing(message: "File '\(newFilename)' already exists")
        }

        do {
            let resultPath = try rename(path: path, to: newFilename)
            guard let appState else { return .renamed(newPath: resultPath, displayName: newFilename) }
            appState.fileData.setCurrentImagePath(resultPath)
            appState.selection.selectedFiles = [resultPath]
            return .renamed(newPath: resultPath, displayName: newFilename)
        } catch {
            return .blocked(title: "Rename Failed", message: error.localizedDescription)
        }
    }

    func commitDirectoryRename(path: String, newName: String) -> InlineRenameOutcome {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldName = ((path as NSString).standardizingPath as NSString).lastPathComponent
        if trimmed == oldName { return .unchanged }

        if let error = Self.validateDirectoryName(trimmed) {
            return .blocked(title: "Invalid Directory Name", message: error)
        }

        let parent = ((path as NSString).standardizingPath as NSString).deletingLastPathComponent
        let newPath = (parent as NSString).appendingPathComponent(trimmed)
        if FileManager.default.fileExists(atPath: newPath) {
            return .blocked(
                title: "Rename Failed",
                message: "A directory named '\(trimmed)' already exists."
            )
        }

        do {
            try FileManager.default.moveItem(atPath: path, toPath: newPath)
            guard let appState else { return .renamed(newPath: newPath, displayName: trimmed) }
            appState.applyFileTreeDirectoryRename(oldPath: path, newPath: newPath)
            return .renamed(newPath: newPath, displayName: trimmed)
        } catch {
            return .blocked(title: "Rename Failed", message: "Failed to rename directory: \(error.localizedDescription)")
        }
    }

    func applyInlineRenameOutcome(_ outcome: InlineRenameOutcome) {
        switch outcome {
        case .unchanged:
            break
        case .renamed(_, let displayName):
            appState?.status.show("Renamed to \(displayName)")
        case .keepEditing(let message):
            appState?.status.show(message)
        case .blocked(let title, let message):
            showAlert(title, message)
        }
    }

    /// Port of `file_move_handler.resolve_target_path` loop in `file_tree_handler` / `_move_files_to_directory`.
    func transferFiles(
        paths: [String],
        to targetDirectory: String,
        copyOnly: Bool,
        refreshWhenDone: Bool = true,
        parentWindow: NSWindow? = nil
    ) -> FileBatchTransferOutcome {
        var outcome = FileBatchTransferOutcome()
        guard let appState else { return outcome }

        let files = paths.filter { path in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return false }
            return !isDir.boolValue
        }
        guard !files.isEmpty else { return outcome }

        guard allowPhotosLibraryTransfer(paths: files, targetDirectory: targetDirectory, copyOnly: copyOnly) else {
            return outcome
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
                return outcome
            }
        }

        guard FileManager.default.isWritableFile(atPath: targetDirectory) else {
            let op = copyOnly ? "Copy" : "Move"
            showAlert(
                "Cannot \(op) Files",
                """
                Cannot \(op.lowercased()) files to destination:

                \(targetDirectory)

                Reason: Destination is read-only or you don't have write permission.

                Please check the destination permissions or choose a different location.
                """
            )
            return outcome
        }

        let suppressSeconds = max(2.0, Double(files.count) * 0.35 + 1.0)
        appState.beginSuppressDirectoryRefresh(minimumDuration: suppressSeconds)
        defer { appState.endSuppressDirectoryRefresh() }

        let displayed = appState.fileData.displayedImages
        let config = appState.config
        var applyToAllState = FileMoveConflictResolver.ApplyToAllState()
        let fm = FileManager.default
        let targetReal = RenamePrefixPlanner.realPath(targetDirectory)

        var progress: ProgressPanelController?
        if files.count > 10 {
            let title = copyOnly ? "Copying Files" : "Moving Files"
            progress = ProgressPanelController(title: title, labelText: title, maximum: files.count)
            progress?.show()
        }
        defer { progress?.close() }

        let opLabel = copyOnly ? "Copying" : "Moving"
        appState.config.debugLog("transferFiles starting \(files.count) file(s) copyOnly=\(copyOnly)")

        for (idx, sourcePath) in files.enumerated() {
            progress?.update(
                value: idx,
                label: "\(opLabel) file \(idx + 1) of \(files.count)"
            )

            let sourceDir = RenamePrefixPlanner.realPath((sourcePath as NSString).deletingLastPathComponent)
            if sourceDir == targetReal {
                outcome.skippedCount += 1
                appState.status.show("file \(copyOnly ? "copy" : "move") skipped, src=dest")
                progress?.update(value: idx + 1)
                continue
            }

            let (resolvedPath, cancelAll) = FileMoveConflictResolver.resolveTargetPath(
                sourcePath: sourcePath,
                targetDirectory: targetDirectory,
                applyToAllState: &applyToAllState,
                config: config,
                parentWindow: parentWindow
            )

            if cancelAll {
                outcome.userCancelled = true
                appState.config.debugLog(
                    "transferFiles cancelAll at \(idx + 1)/\(files.count) \((sourcePath as NSString).lastPathComponent)"
                )
                break
            }
            guard let targetPath = resolvedPath else {
                outcome.skippedCount += 1
                appState.config.debugLog(
                    "transferFiles skipped \(idx + 1)/\(files.count) \((sourcePath as NSString).lastPathComponent)"
                )
                progress?.update(value: idx + 1)
                continue
            }

            let sourceURL = URL(fileURLWithPath: sourcePath)
            do {
                if fm.fileExists(atPath: targetPath) {
                    try fm.removeItem(atPath: targetPath)
                }
                try fm.copyItem(at: sourceURL, to: URL(fileURLWithPath: targetPath))
            } catch {
                let name = (sourcePath as NSString).lastPathComponent
                outcome.failedFilenames.append(name)
                outcome.skippedCount += 1
                progress?.update(value: idx + 1)
                continue
            }

            if copyOnly {
                outcome.successCount += 1
                outcome.transfers.append((source: sourcePath, target: targetPath))
            } else {
                do {
                    try fm.removeItem(at: sourceURL)
                    outcome.successCount += 1
                    outcome.transfers.append((source: sourcePath, target: targetPath))
                    outcome.undoEntries.append(
                        MovedFileUndoEntry(
                            sourcePath: sourcePath,
                            targetPath: targetPath,
                            originalPosition: displayed.firstIndex(of: sourcePath)
                        )
                    )
                } catch {
                    try? fm.removeItem(atPath: targetPath)
                    outcome.failedFilenames.append((sourcePath as NSString).lastPathComponent)
                    outcome.skippedCount += 1
                }
            }
            progress?.update(value: idx + 1)
        }

        if !outcome.undoEntries.isEmpty {
            undoStack.pushMove(outcome.undoEntries)
        }
        if refreshWhenDone, outcome.successCount > 0 {
            let removedSources = copyOnly ? [] : outcome.transfers.map(\.source)
            refreshAfterChange(removedPaths: removedSources)
        }
        return outcome
    }

    func copy(paths: [String], to directory: String) throws -> [String] {
        let outcome = transferFiles(paths: paths, to: directory, copyOnly: true, refreshWhenDone: true)
        if outcome.failedFilenames.isEmpty {
            return outcome.transfers.map(\.target)
        }
        throw NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteUnknownError,
            userInfo: [NSLocalizedDescriptionKey: "Failed to copy \(outcome.failedFilenames.count) file(s)"]
        )
    }

    func move(paths: [String], to directory: String, refreshWhenDone: Bool = true) throws -> [String] {
        let outcome = transferFiles(
            paths: paths,
            to: directory,
            copyOnly: false,
            refreshWhenDone: refreshWhenDone
        )
        if outcome.failedFilenames.isEmpty {
            return outcome.transfers.map(\.target)
        }
        throw NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteUnknownError,
            userInfo: [NSLocalizedDescriptionKey: "Failed to move \(outcome.failedFilenames.count) file(s)"]
        )
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

        let outcome = transferFiles(paths: paths, to: expanded, copyOnly: shouldCopy, refreshWhenDone: true)
        reportBatchTransferOutcome(
            outcome,
            copyOnly: shouldCopy,
            targetDirectory: expanded,
            successStatus: { count in
                if shouldCopy {
                    "Copied \(count) file(s) to destination \(slot)"
                } else {
                    "Moved \(count) file(s) to destination \(slot)"
                }
            }
        )
    }

    /// File-tree drop target. Port of `files/file_tree_handler.py` ``dropEvent``.
    @discardableResult
    func performFileTreeDrop(filePaths: [String], targetDirectory: String, operation: NSDragOperation) -> Bool {
        guard let appState else { return false }

        let mergedPaths = FileTreeOutlineView.mergedDropFilePaths(
            pasteboardPaths: filePaths,
            appState: appState
        )
        let files = mergedPaths.filter { path in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return false }
            return !isDir.boolValue
        }
        guard !files.isEmpty else { return false }

        let firstName = files.first.map { ($0 as NSString).lastPathComponent } ?? "?"
        appState.config.debugLog("FileTree drop batch count=\(files.count) first=\(firstName)")

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

        appState.suspendFileTreeHighlightSync()
        defer { appState.resumeFileTreeHighlightSync() }

        let displayed = appState.fileData.displayedImages
        let activePath = appState.fileData.currentImagePath
        let selectedBeforeDrop = appState.selection.selectedFiles
        let outcome = transferFiles(
            paths: files,
            to: targetDirectory,
            copyOnly: copyOnly,
            refreshWhenDone: false
        )

        if !outcome.failedFilenames.isEmpty {
            showTransferFailedAlert(
                copyOnly: copyOnly,
                failedCount: outcome.failedFilenames.count,
                targetDirectory: targetDirectory
            )
        }

        guard outcome.successCount > 0 else {
            if !outcome.userCancelled,
               outcome.failedFilenames.isEmpty,
               outcome.skippedCount == 0 {
                let title = copyOnly ? "Cannot Copy Files" : "Cannot Move Files"
                let text = """
                Cannot \(copyOnly ? "copy" : "move") files to destination:

                \(targetDirectory)

                No files were \(copyOnly ? "copied" : "moved"). All files may have been skipped due to overwrite conflicts.
                """
                StyledMessageDialog.showCritical(title: title, message: text)
            } else if outcome.skippedCount > 0, !outcome.userCancelled {
                appState.status.showFileOperation(copyOnly ? "No files copied" : "No files moved")
            }
            return false
        }

        if copyOnly {
            appState.config.debugLog(
                "FileTree copy completed count=\(outcome.successCount) dest=\(targetDirectory)"
            )
            if outcome.skippedCount > 0 {
                appState.status.showFileOperation(
                    "Copied \(outcome.successCount) file(s), skipped \(outcome.skippedCount)"
                )
            } else {
                appState.status.showFileOperation("Copied \(outcome.successCount) file(s)")
            }
            refreshDirectoryAfterTreeDrop(
                appState: appState,
                sourcePaths: mergedPaths,
                targetDirectory: targetDirectory,
                copyOnly: true
            )
        } else {
            let movedSources = outcome.transfers.map(\.source)
            if outcome.skippedCount > 0 {
                appState.status.showFileOperation(
                    "Moved \(outcome.successCount) file(s), skipped \(outcome.skippedCount)"
                )
            } else {
                appState.status.showFileOperation("Moved \(outcome.successCount) file(s)")
            }
            DirectoryRefreshService.applyRemovedFiles(
                appState: appState,
                removed: Set(movedSources),
                displayed: displayed,
                activePath: activePath
            )
            let movedSet = Set(movedSources)
            if selectedBeforeDrop.isEmpty {
                appState.selection.selectedFiles.subtract(movedSet)
            } else {
                appState.selection.selectedFiles = selectedBeforeDrop.subtracting(movedSet)
            }
            appState.selection.emitSelectionChanged(highlightIndex: appState.fileData.currentIndex)
            refreshDirectoryAfterTreeDrop(
                appState: appState,
                sourcePaths: mergedPaths,
                targetDirectory: targetDirectory,
                copyOnly: false
            )
        }
        return true
    }

    private func refreshDirectoryAfterTreeDrop(
        appState: AppState,
        sourcePaths: [String],
        targetDirectory: String,
        copyOnly: Bool
    ) {
        // Python file_tree drop: remove_thumbnails_for_files + debounced refresh only (no load_directory).
        if appState.specificFilesActive || appState.referenceGraphActive {
            if copyOnly {
                let currentNorm = appState.fileData.currentDirectory.flatMap {
                    FileDataModel.normalizePath($0) ?? $0
                }
                let targetNorm = FileDataModel.normalizePath(targetDirectory) ?? targetDirectory
                if currentNorm == targetNorm {
                    DirectoryRefreshService.refreshSpecificFilesList(appState: appState, force: false)
                }
            }
            return
        }

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

    func moveToLastDropLocation(copyOnly: Bool? = nil) {
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

        let shouldCopy: Bool
        if let copyOnly {
            shouldCopy = copyOnly
        } else {
            let action = appState.config.string(forKey: "destination_menu_action", default: "move")
            if action == "none" { return }
            shouldCopy = action == "copy"
        }

        let outcome = transferFiles(paths: paths, to: lastDrop, copyOnly: shouldCopy, refreshWhenDone: true)
        reportBatchTransferOutcome(
            outcome,
            copyOnly: shouldCopy,
            targetDirectory: lastDrop,
            successStatus: { _ in
                shouldCopy ? "Copied to last drop location" : "Moved to last drop location"
            }
        )
    }

    func copyPathsToClipboard(_ paths: [String]) {
        guard let appState, !paths.isEmpty else { return }
        let text: String
        if paths.count > 1 {
            text = paths
                .map { "[\(InformationFormatting.normalizePathForDisplay($0))]" }
                .joined(separator: " ")
        } else {
            text = InformationFormatting.normalizePathForDisplay(paths[0])
        }
        appState.copyTextToClipboard(text)
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
        appState.copyFeedback.show()
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
        if locked {
            guard appState.config.bool(forKey: "allow_thumbnail_locking", default: false) else { return }
        }

        if appState.fileData.currentViewMode == .thumbnail, appState.specificFilesActive {
            return
        }

        let selected = paths ?? SelectionService.pathsForLockUnlock(appState: appState)
        guard !selected.isEmpty else {
            appState.status.show("No files selected")
            return
        }
        let directories = Set(selected.map { ($0 as NSString).deletingLastPathComponent })
        guard directories.count == 1, let directory = directories.first else {
            showAlert("Lock Files", "Select files from a single directory to lock or unlock.")
            return
        }

        let switchedToCustom: Bool
        if locked,
           appState.fileData.currentViewMode == .thumbnail,
           appState.config.string(forKey: "sort_mode", default: SortMode.date.rawValue) != SortMode.custom.rawValue {
            appState.config.updateSetting("sort_mode", value: SortMode.custom.rawValue)
            switchedToCustom = true
        } else {
            switchedToCustom = false
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
            appState.beginSuppressDirectoryRefresh()
            defer { appState.endSuppressDirectoryRefresh() }
            if switchedToCustom {
                appState.scheduleDeferredMenuRefresh()
            } else if !locked {
                _ = ThumbnailLockOrdering.applyLockFirstOrderIfNeeded(appState: appState)
            }
            appState.repaintThumbnailLockIndicators()
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

    private func reportBatchTransferOutcome(
        _ outcome: FileBatchTransferOutcome,
        copyOnly: Bool,
        targetDirectory: String,
        successStatus: (Int) -> String
    ) {
        guard let appState else { return }

        if !outcome.failedFilenames.isEmpty {
            showTransferFailedAlert(
                copyOnly: copyOnly,
                failedCount: outcome.failedFilenames.count,
                targetDirectory: targetDirectory
            )
        }

        if outcome.successCount > 0 {
            if outcome.skippedCount > 0 {
                let verb = copyOnly ? "Copied" : "Moved"
                appState.status.show("\(verb) \(outcome.successCount) file(s), skipped \(outcome.skippedCount)")
            } else {
                appState.status.show(successStatus(outcome.successCount))
            }
            return
        }

        if outcome.userCancelled { return }

        if outcome.failedFilenames.isEmpty, outcome.skippedCount > 0 {
            appState.status.show(copyOnly ? "No files copied" : "No files moved")
        } else if outcome.failedFilenames.isEmpty, outcome.skippedCount == 0 {
            let title = copyOnly ? "Cannot Copy Files" : "Cannot Move Files"
            let text = """
            Cannot \(copyOnly ? "copy" : "move") files to destination:

            \(targetDirectory)

            No files were \(copyOnly ? "copied" : "moved"). All files may have been skipped due to overwrite conflicts.
            """
            StyledMessageDialog.showCritical(title: title, message: text)
        }
    }

    private func showTransferFailedAlert(copyOnly: Bool, failedCount: Int, targetDirectory: String) {
        let op = copyOnly ? "copy" : "move"
        let title = copyOnly ? "Copy Failed" : "Move Failed"
        let message: String
        if failedCount == 1 {
            message = """
            Failed to \(op) file.

            Destination: \(targetDirectory)

            Please check file permissions and try again.
            """
        } else {
            message = """
            Failed to \(op) \(failedCount) files.

            Destination: \(targetDirectory)

            Please check file permissions and try again.
            """
        }
        StyledMessageDialog.showCritical(title: title, message: message)
    }

    private func showAlert(_ title: String, _ message: String) {
        StyledMessageDialog.showWarning(title: title, message: message)
    }

    /// After file ops, refresh the UI without leaving a specific-files level (⌘K / ⌘F / duplicates).
    private func refreshAfterChange(removedPaths: [String] = []) {
        guard let appState else { return }

        if appState.specificFilesActive || appState.referenceGraphActive {
            let displayed = appState.fileData.displayedImages
            let activePath = appState.fileData.currentImagePath
            if !removedPaths.isEmpty {
                DirectoryRefreshService.applyRemovedFiles(
                    appState: appState,
                    removed: Set(removedPaths),
                    displayed: displayed,
                    activePath: activePath
                )
                let removedSet = Set(removedPaths)
                if !appState.selection.selectedFiles.isEmpty {
                    appState.selection.selectedFiles.subtract(removedSet)
                }
                appState.selection.emitSelectionChanged(highlightIndex: appState.fileData.currentIndex)
            } else {
                DirectoryRefreshService.refreshSpecificFilesList(appState: appState, force: false)
            }
            if let directory = appState.fileData.currentDirectory {
                appState.eventBus.emit(.filesChangedOnDisk, payload: .string(directory))
            }
            appState.refreshMenuState()
            return
        }

        guard let directory = appState.fileData.currentDirectory else { return }
        appState.loadDirectory(directory, saveHistory: false)
        appState.eventBus.emit(.filesChangedOnDisk, payload: .string(directory))
    }
}
