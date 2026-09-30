import AppKit
import Foundation

/// "Rename with Custom Prefix" and "Quick Mass Rename".
/// Port of `FileOperationsManager.rename_with_custom_prefix`, `quick_mass_rename` and
/// `_highlight_first_non_locked_after_rename` in `files/file_operations_manager.py`.
///
/// Pure planning algorithms live in ``RenamePrefixPlanner``; the dialog is ``RenamePrefixSheet``.
/// Feature-cache (CNN/CLIP/face) MD5 hand-off is not ported: those caches live in the Python
/// workers, which are flushed/paused around the rename and resumed afterwards.
@MainActor
final class RenamePrefixService {
    typealias Options = RenamePrefixPlanner.Options
    typealias Mapping = RenamePrefixPlanner.Mapping

    /// Python `QUICK_MASS_RENAME_USE_USER_SETTINGS`.
    static let quickMassRenameUseUserSettings = true
    private static let defaultPrefixTemplate = "image-%d"

    private weak var appState: AppState?

    /// State captured before the dialog is shown, consumed by ``dialogFinished``.
    private struct PendingRename {
        var imagesToRename: [String]
        var displayedImages: [String]
        var highlightedPath: String?
        var targetDirectory: String
        var bypassDialog: Bool
    }

    private var pending: PendingRename?

    func bind(_ appState: AppState) {
        self.appState = appState
    }

    // MARK: - Entry points

    /// Port of `quick_mass_rename`: select all and rename with presets (no dialog).
    func quickMassRename() {
        guard let appState else { return }
        let settings = appState.config.rawSettings()
        guard settings["allow_quick_mass_rename"] as? Bool ?? false else {
            StyledMessageDialog.showWarning(
                title: "Quick Mass Rename",
                message: "Quick Mass Rename is disabled in settings.\n\nPlease enable it in Settings to use this feature."
            )
            return
        }
        guard appState.fileData.currentViewMode == .thumbnail else {
            StyledMessageDialog.showWarning(
                title: "Quick Mass Rename",
                message: "Quick Mass Rename is only available in thumbnail view"
            )
            return
        }
        if appState.specificFilesActive {
            StyledMessageDialog.showWarning(
                title: "Quick Mass Rename",
                message: "Quick Mass Rename is not available when viewing specific files.\n\n"
                    + "Please open a directory instead of specific files to use this feature."
            )
            return
        }

        // Select all thumbnails (same as cmd-A)
        appState.fileOperations.selectAllDisplayed()

        let prefixTemplate = settings["rename_custom_prefix"] as? String ?? Self.defaultPrefixTemplate
        let incrementLength = appState.config.int(forKey: "rename_increment_length", default: 5)
        let startingNumber = appState.config.int(forKey: "rename_starting_number", default: 1)

        let sortMode: RenamePrefixPlanner.SortMode
        let dateChangeMode: RenamePrefixPlanner.DateChangeMode
        let orderDirection: RenamePrefixPlanner.OrderDirection
        if Self.quickMassRenameUseUserSettings {
            sortMode = .init(rawValue: appState.config.string(forKey: "rename_sort_mode", default: "order")) ?? .order
            dateChangeMode = .init(rawValue: appState.config.string(forKey: "rename_date_change_mode", default: "none")) ?? .none
            orderDirection = .init(rawValue: appState.config.string(forKey: "rename_order_direction", default: "top")) ?? .top
        } else {
            sortMode = .order
            dateChangeMode = .none
            orderDirection = .top
        }

        renameWithCustomPrefix(
            bypassDialog: true,
            prefixTemplate: prefixTemplate,
            incrementLength: incrementLength,
            startingNumber: startingNumber,
            sortMode: sortMode,
            dateChangeMode: dateChangeMode,
            orderDirection: orderDirection
        )
    }

    /// Port of `rename_with_custom_prefix` up to (and including) the dialog.
    func renameWithCustomPrefix(
        bypassDialog: Bool = false,
        prefixTemplate: String? = nil,
        incrementLength: Int? = nil,
        startingNumber: Int? = nil,
        sortMode: RenamePrefixPlanner.SortMode? = nil,
        dateChangeMode: RenamePrefixPlanner.DateChangeMode? = nil,
        orderDirection: RenamePrefixPlanner.OrderDirection? = nil
    ) {
        guard let appState else { return }
        let config = appState.config

        // Use saved config for date_change_mode if not provided
        let dateChangeMode = dateChangeMode
            ?? RenamePrefixPlanner.DateChangeMode(rawValue: config.string(forKey: "rename_date_change_mode", default: "none"))
            ?? .none

        // Only available in thumbnail view
        guard appState.fileData.currentViewMode == .thumbnail else {
            appState.status.show("Rename with custom prefix is only available in thumbnail view")
            return
        }

        // Python `selection_manager.get_selected_files()`: falls back to the highlighted image
        let selectedFiles = Set(SelectionService.selectedFilesOrCurrent(appState: appState))
        guard !selectedFiles.isEmpty else {
            appState.status.show("No files selected. Please select files to rename.")
            return
        }

        // Photos Library files cannot be renamed
        if selectedFiles.contains(where: RenamePrefixPlanner.isInsidePhotosLibrary) {
            StyledMessageDialog.showWarning(
                title: "Operation Not Allowed",
                message: "Renaming files within macOS Photos Library is not allowed.\n\n"
                    + "Photos Library files cannot be renamed or modified."
            )
            return
        }

        let displayedImages = appState.fileData.displayedImages

        // When locked files exist, every displayed file must be selected
        let firstDirectory = (selectedFiles.first! as NSString).deletingLastPathComponent
        let hasLockedFiles = !PrsortIO.lockedFilenames(in: firstDirectory).isEmpty
        if hasLockedFiles {
            let displayedSet = Set(displayedImages)
            if displayedSet != selectedFiles {
                let missing = displayedSet.subtracting(selectedFiles).count
                StyledMessageDialog.showWarning(
                    title: "Not All Files Selected",
                    message: "Because there are locked files, all files in the displayed list must be selected before renaming.\n\n"
                        + "\(missing) \(RenamePrefixPlanner.fileString(missing)) are not selected.\n\n"
                        + "Please select all files (Cmd-A) before renaming."
                )
                return
            }
        }

        // Single file: recommend multi-select (Cancel | Continue, Continue is default)
        if !bypassDialog, selectedFiles.count == 1 {
            let choice = StyledMessageDialog.present(
                title: "Single File Selected",
                message: "Only one image is selected. Rename with custom prefix is intended for multiple selections.\n\n"
                    + "Do you want to rename only one file?",
                style: .warning,
                icon: .warning,
                buttons: [
                    StyledMessageDialog.Button("Cancel", role: .dismissive),
                    StyledMessageDialog.Button("Continue"),
                ],
                defaultButtonIndex: 1,
                escapeButtonIndex: 0
            )
            guard choice == 1 else { return }
        }

        // Empty filter pattern warning (OK | Cancel, Cancel is default).
        // Python: `if not bypass_dialog and not mw.filter_pattern` — the pattern is normalised to "*"
        // when blank, so this only fires for a genuinely empty pattern.
        if !bypassDialog, appState.filterSettings.filterPattern.isEmpty {
            let choice = StyledMessageDialog.present(
                title: "All Files will be Renamed",
                message: "Rename all files with a custom prefix\n\nThe filter pattern is empty. This may lead to unwanted files being renamed.\n\n",
                style: .warning,
                icon: .warning,
                buttons: [
                    StyledMessageDialog.Button("Cancel", role: .dismissive),
                    StyledMessageDialog.Button("OK"),
                ],
                defaultButtonIndex: 0,
                escapeButtonIndex: 0
            )
            guard choice == 1 else { return }
        }

        // Displayed order is the source of truth for rename order (selection is an unordered set)
        var imagesToRename = displayedImages.filter { selectedFiles.contains($0) }
        for path in selectedFiles where !imagesToRename.contains(path) {
            imagesToRename.append(path)
        }
        let highlightedPath = appState.fileData.currentImagePath

        guard !imagesToRename.isEmpty else {
            appState.status.show("No images to rename")
            return
        }

        // Only a single directory is accepted
        let directories = Set(
            imagesToRename
                .filter { FileManager.default.fileExists(atPath: $0) }
                .map { ($0 as NSString).deletingLastPathComponent }
        )
        guard directories.count == 1, let targetDirectory = directories.first else {
            StyledMessageDialog.showWarning(
                title: "Multiple Directories",
                message: "All selected images must be in the same directory. Multiple directories are not supported."
            )
            return
        }

        guard FileManager.default.isWritableFile(atPath: targetDirectory) else {
            StyledMessageDialog.showWarning(
                title: "Directory Not Writable",
                message: "The directory is not writable:\n\n\(targetDirectory)\n\n"
                    + "You do not have permission to rename files in this directory."
            )
            return
        }

        let settings = config.rawSettings()
        var bypass = bypassDialog
        var resolvedTemplate = prefixTemplate
        var resolvedIncrement = incrementLength
        var resolvedStarting = startingNumber
        var resolvedSortMode = sortMode
        var resolvedDirection = orderDirection
        if bypass {
            if resolvedTemplate == nil {
                resolvedTemplate = settings["rename_custom_prefix"] as? String ?? Self.defaultPrefixTemplate
            }
            if resolvedIncrement == nil { resolvedIncrement = config.int(forKey: "rename_increment_length", default: 5) }
            if resolvedStarting == nil { resolvedStarting = config.int(forKey: "rename_starting_number", default: 1) }
            if resolvedSortMode == nil { resolvedSortMode = .order }
            if resolvedDirection == nil { resolvedDirection = .top }
            // Blank/whitespace prefix: show the dialog so the user can set one
            if (resolvedTemplate ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bypass = false
            }
        }

        pending = PendingRename(
            imagesToRename: imagesToRename,
            displayedImages: displayedImages,
            highlightedPath: highlightedPath,
            targetDirectory: targetDirectory,
            bypassDialog: bypass
        )

        if bypass {
            let options = Options(
                prefixTemplate: resolvedTemplate ?? Self.defaultPrefixTemplate,
                incrementLength: resolvedIncrement ?? 5,
                startingNumber: resolvedStarting ?? 1,
                sortMode: resolvedSortMode ?? .order,
                dateChangeMode: dateChangeMode,
                orderDirection: resolvedDirection ?? .top
            )
            dialogFinished(options)
            return
        }

        appState.renamePrefixDialog = RenamePrefixDialogRequest(
            savedPrefix: settings["rename_custom_prefix"] as? String ?? "",
            savedIncrementLength: config.int(forKey: "rename_increment_length", default: 5),
            savedStartingNumber: config.int(forKey: "rename_starting_number", default: 1),
            savedSortMode: .init(rawValue: config.string(forKey: "rename_sort_mode", default: "date")) ?? .date,
            savedDateChangeMode: .init(rawValue: config.string(forKey: "rename_date_change_mode", default: "none")) ?? .none,
            savedOrderDirection: .init(rawValue: config.string(forKey: "rename_order_direction", default: "top")) ?? .top
        )
    }

    /// Called by ``RenamePrefixSheet`` (or directly when bypassing the dialog).
    func dialogFinished(_ options: Options?) {
        guard let context = pending else { return }
        pending = nil
        guard let options else { return }
        if context.bypassDialog {
            continueRename(context: context, options: options)
        } else {
            // Let the sheet dismiss before the synchronous rename shows its own panels.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.continueRename(context: context, options: options)
            }
        }
    }

    // MARK: - Post-dialog flow

    private func continueRename(context: PendingRename, options: Options) {
        guard let appState else { return }
        let config = appState.config
        let fm = FileManager.default
        let targetDirectory = context.targetDirectory
        let displayedImages = context.displayedImages
        var imagesToRename = context.imagesToRename
        let bypassDialog = context.bypassDialog
        let sortMode = options.sortMode
        let dateChangeMode = options.dateChangeMode
        let orderDirection = options.orderDirection
        let incrementLength = options.incrementLength
        let startingNumber = options.startingNumber

        // Save the display sort mode so it can be restored after rename
        let originalDisplaySortMode = SortMode(rawValue: config.string(forKey: "sort_mode", default: "date")) ?? .date

        var dirname = (targetDirectory as NSString).lastPathComponent
        if dirname.isEmpty { dirname = "directory" }
        let prefix = options.prefixTemplate
            .replacingOccurrences(of: "%d", with: dirname)
            .replacingOccurrences(of: "%D", with: dirname)
        if let error = RenamePrefixPlanner.validateUnixFilename(prefix) {
            var detail = "Invalid prefix: \(error)\n\nPlease enter a valid Unix filename prefix."
            if prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                detail += "\n\nSet a prefix via Edit → Rename with Custom Prefix (Ctrl+N). "
                    + "Quick Mass Rename uses the last prefix saved there."
            }
            StyledMessageDialog.showWarning(title: "Invalid Prefix", message: detail)
            return
        }
        let maxSequence = Int(pow(10.0, Double(incrementLength))) - 1
        if startingNumber > maxSequence {
            StyledMessageDialog.showWarning(
                title: "Invalid Starting Number",
                message: "Starting number \(startingNumber) exceeds maximum \(maxSequence) for \(incrementLength) digits.\n\n"
                    + "Please use a starting number between 1 and \(maxSequence)."
            )
            return
        }

        // Persist dialog settings (before any further confirmation so they survive a cancel)
        config.updateSetting("rename_custom_prefix", value: options.prefixTemplate)
        config.updateSetting("rename_increment_length", value: incrementLength)
        config.updateSetting("rename_starting_number", value: startingNumber)
        if !bypassDialog || !Self.quickMassRenameUseUserSettings {
            config.updateSetting("rename_sort_mode", value: sortMode.rawValue)
            config.updateSetting("rename_date_change_mode", value: dateChangeMode.rawValue)
            config.updateSetting("rename_order_direction", value: orderDirection.rawValue)
        }

        // Only files that exist inside the target directory
        imagesToRename = imagesToRename.filter {
            fm.fileExists(atPath: $0) && ($0 as NSString).deletingLastPathComponent == targetDirectory
        }
        guard !imagesToRename.isEmpty else {
            appState.status.show("No images to rename")
            return
        }

        // "order" mode: consolidate locked files to the top (in their .prsort order)
        if sortMode == .order {
            let lockedNames = PrsortIO.lockedFilenames(in: targetDirectory)
            if !lockedNames.isEmpty {
                let (locked, unlocked) = PrsortIO.separateLockedUnlocked(imagesToRename)
                imagesToRename = locked + unlocked
            }
        }

        // Permission checks
        guard fm.isWritableFile(atPath: targetDirectory) else {
            StyledMessageDialog.showWarning(
                title: "Permission Error",
                message: "The directory '\(dirname)' is not writable.\n\nPlease check directory permissions and try again."
            )
            return
        }
        let testFilePath = (targetDirectory as NSString).appendingPathComponent(".prowser_rename_test")
        do {
            try "test".write(toFile: testFilePath, atomically: false, encoding: .utf8)
            try fm.removeItem(atPath: testFilePath)
        } catch {
            if fm.fileExists(atPath: testFilePath) { try? fm.removeItem(atPath: testFilePath) }
            StyledMessageDialog.showWarning(
                title: "Permission Error",
                message: "Cannot write to directory '\(dirname)'.\n\nError: \(error.localizedDescription)\n\n"
                    + "Please check directory permissions and try again."
            )
            return
        }

        var nonRenameable: [(String, String)] = []
        for path in imagesToRename {
            let name = (path as NSString).lastPathComponent
            if !fm.fileExists(atPath: path) {
                nonRenameable.append((name, "File does not exist"))
            } else if !fm.isWritableFile(atPath: (path as NSString).deletingLastPathComponent) {
                nonRenameable.append((name, "Parent directory not writable"))
            } else if !fm.isWritableFile(atPath: path) {
                nonRenameable.append((name, "Permission denied: cannot rename file"))
            }
        }
        if !nonRenameable.isEmpty {
            StyledMessageDialog.showWarning(
                title: "Permission Error",
                message: "Cannot rename some files in '\(dirname)'.\n\n"
                    + "Files with permission issues:\n\(Self.formatErrorList(nonRenameable))\n\n"
                    + "Please check file permissions and try again."
            )
            return
        }

        // Progress dialog: preparation phase is 100 steps (sorting 0-10, names 10-50, plan 50-100)
        let numImages = imagesToRename.count
        let prepTotal = 100
        let progress = ProgressPanelController(title: "Rename Files", labelText: "Preparing rename...", maximum: prepTotal)
        progress.show()

        func updateProgress(_ current: Int, _ total: Int, _ message: String, _ phaseStart: Int, _ phaseEnd: Int) {
            let value = total > 0 ? phaseStart + (phaseEnd - phaseStart) * current / total : phaseStart
            progress.update(value: value, label: message)
        }

        // Locked files order (from .prsort) preserved BEFORE any sorting
        let lockedFilesOrder: [String] = {
            guard !PrsortIO.lockedFilenames(in: targetDirectory).isEmpty else { return [] }
            return PrsortIO.separateLockedUnlocked(imagesToRename).locked
        }()

        let isPartialSelection = imagesToRename.count < displayedImages.count
        NSLog(
            "[RenamePrefix] prefix=%@ digits=%d start=%d sort=%@ dates=%@ dir=%@ selected=%d displayed=%d partial=%@",
            prefix, incrementLength, startingNumber, sortMode.rawValue, dateChangeMode.rawValue,
            orderDirection.rawValue, imagesToRename.count, displayedImages.count, isPartialSelection ? "YES" : "NO"
        )

        // --------- SORT LOGIC ------------------
        var originalDisplayedOrder: [String]?
        progress.updateStatus(label: "Sorting images...")

        // Partial selection always uses thumbnail-list order (ignore dialog date sort).
        if sortMode == .order || isPartialSelection {
            originalDisplayedOrder = imagesToRename

            // Dates by displayed position happen BEFORE reversal for numbering
            if dateChangeMode.changesDates {
                progress.updateStatus(label: "Setting file dates based on displayed order...")
                let now = Int(Date().timeIntervalSince1970)
                let changes = RenamePrefixPlanner.minimizeDateChanges(
                    filesWithIndices: imagesToRename.enumerated().map { ($1, $0) },
                    mode: dateChangeMode,
                    now: now,
                    totalFiles: imagesToRename.count
                )
                applyDateChanges(changes)
            }

            // "Bottom becomes 1": reverse for numbering only (display keeps original order)
            if orderDirection == .bottom, sortMode == .order {
                imagesToRename.reverse()
            }
            progress.update(value: 10)
        } else {
            // "date": set dates first (based on the final sequence order) so the sort uses them
            if dateChangeMode.changesDates {
                progress.updateStatus(label: "Calculating final order for date setting...")
                let now = Int(Date().timeIntervalSince1970)
                do {
                    var temp = try RenamePrefixPlanner.calculateTargetNames(
                        images: imagesToRename,
                        prefix: prefix,
                        directory: targetDirectory,
                        incrementLength: incrementLength,
                        startingNumber: startingNumber
                    )
                    temp.sort { RenamePrefixPlanner.sequenceNumber(of: $0.target, prefix: prefix)
                        < RenamePrefixPlanner.sequenceNumber(of: $1.target, prefix: prefix) }
                    var seqIndex: [String: Int] = [:]
                    for (idx, mapping) in temp.enumerated() { seqIndex[mapping.source] = idx }

                    progress.updateStatus(label: "Setting file dates for sorting...")
                    let files = imagesToRename.compactMap { path -> (String, Int)? in
                        guard fm.fileExists(atPath: path), let idx = seqIndex[path] else { return nil }
                        return (path, idx)
                    }
                    let changes = RenamePrefixPlanner.minimizeDateChanges(
                        filesWithIndices: files, mode: dateChangeMode, now: now, totalFiles: temp.count
                    )
                    applyDateChanges(changes)
                } catch {
                    NSLog("Error calculating target names for date setting: \(error)")
                    let changes = RenamePrefixPlanner.minimizeDateChanges(
                        filesWithIndices: imagesToRename.enumerated().map { ($1, $0) },
                        mode: dateChangeMode,
                        now: now,
                        totalFiles: imagesToRename.count
                    )
                    applyDateChanges(changes)
                }
            }

            // Sort by modification date, oldest first (Python `get_sort_key` = mtime)
            progress.updateStatus(label: "Reading file dates...")
            var keyed: [(mtime: Double, index: Int, path: String)] = []
            for (idx, path) in imagesToRename.enumerated() {
                if idx % 50 == 0 {
                    updateProgress(idx, numImages, "Reading file dates... (\(idx)/\(numImages))", 0, 8)
                }
                keyed.append((Self.modificationTime(path) ?? 0, idx, path))
            }
            progress.updateStatus(label: "Sorting images...")
            keyed.sort { ($0.mtime, $0.index) < ($1.mtime, $1.index) }
            imagesToRename = keyed.map(\.path)

            if orderDirection == .bottom {
                imagesToRename.reverse()
            }
            progress.update(value: 10)
        }

        // Target names (partial selection: start after the highest occupied number)
        let targetMappings: [Mapping]
        do {
            targetMappings = try RenamePrefixPlanner.calculateTargetNames(
                images: imagesToRename,
                prefix: prefix,
                directory: targetDirectory,
                incrementLength: incrementLength,
                startingNumber: startingNumber,
                progress: { updateProgress($0, $1, $2, 10, 50) },
                appendAfterOccupied: isPartialSelection
            )
            progress.update(value: 50, label: "Building rename plan...")
        } catch {
            progress.close()
            StyledMessageDialog.showWarning(title: "Sequence Number Overflow", message: error.localizedDescription)
            return
        }

        let tempPrefix = RenamePrefixPlanner.findAvailableTempPrefix(in: targetDirectory)
        let actualRenames = targetMappings.filter { $0.source != $0.target }
        for mapping in targetMappings.prefix(8) {
            NSLog("[RenamePrefix] %@ -> %@",
                  (mapping.source as NSString).lastPathComponent, (mapping.target as NSString).lastPathComponent)
        }
        NSLog("[RenamePrefix] %d mapping(s), %d actual rename(s)", targetMappings.count, actualRenames.count)

        // Nothing to rename: dates may still need updating
        if actualRenames.isEmpty {
            if dateChangeMode.changesDates {
                progress.updateStatus(label: "Setting file dates...")
                let now = Int(Date().timeIntervalSince1970)
                let changed: [String]
                if sortMode == .order, let original = originalDisplayedOrder {
                    var displayedIndex: [String: Int] = [:]
                    for (idx, path) in original.enumerated() { displayedIndex[path] = idx }
                    let files = targetMappings.compactMap { mapping -> (String, Int)? in
                        guard fm.fileExists(atPath: mapping.target), let idx = displayedIndex[mapping.source] else { return nil }
                        return (mapping.target, idx)
                    }
                    changed = applyDateChanges(RenamePrefixPlanner.minimizeDateChanges(
                        filesWithIndices: files, mode: dateChangeMode, now: now, totalFiles: original.count
                    ))
                } else {
                    let sorted = targetMappings.sorted {
                        RenamePrefixPlanner.sequenceNumber(of: $0.target, prefix: prefix)
                            < RenamePrefixPlanner.sequenceNumber(of: $1.target, prefix: prefix)
                    }
                    let files = sorted.enumerated().compactMap { idx, mapping -> (String, Int)? in
                        fm.fileExists(atPath: mapping.target) ? (mapping.target, idx) : nil
                    }
                    changed = applyDateChanges(RenamePrefixPlanner.minimizeDateChanges(
                        filesWithIndices: files, mode: dateChangeMode, now: now, totalFiles: targetMappings.count
                    ))
                }
                appState.metadataCache.saveIfNeeded()
                notifyThumbnailsChanged(changed)
                appState.selection.clearPreservingCurrentImage()
                progress.close()
                appState.status.show("File dates updated")
            } else {
                appState.selection.clearPreservingCurrentImage()
                progress.close()
                appState.status.show("All files are already correctly named")
                // Still highlight the 1st non-locked item when locked files exist
                let identity = Dictionary(uniqueKeysWithValues: displayedImages.map { ($0, $0) })
                highlightFirstNonLockedAfterRename(directory: targetDirectory, renameMap: identity, preferredPath: nil)
            }
            return
        }

        // Read-only files that would be moved aside in Phase 0 must be renameable
        progress.updateStatus(label: "Checking for conflicting files...")
        var conflictingReadOnly: [(String, String)] = []
        let existingFiles = RenamePrefixPlanner.existingFilesMap(in: targetDirectory)
        let sourcePaths = Set(targetMappings.map { RenamePrefixPlanner.realPath($0.source) })
        for mapping in targetMappings {
            let targetUpper = (mapping.target as NSString).lastPathComponent.uppercased()
            guard let existing = existingFiles[targetUpper],
                  !sourcePaths.contains(RenamePrefixPlanner.realPath(existing)),
                  fm.fileExists(atPath: existing) else { continue }
            let name = (existing as NSString).lastPathComponent
            let fileDir = (existing as NSString).deletingLastPathComponent
            guard fm.isWritableFile(atPath: fileDir) else {
                conflictingReadOnly.append((name, "Parent directory not writable"))
                continue
            }
            let testName = ".prowser_rename_test_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
            let testPath = (fileDir as NSString).appendingPathComponent(testName)
            do {
                try fm.moveItem(atPath: existing, toPath: testPath)
                try fm.moveItem(atPath: testPath, toPath: existing)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteNoPermissionError {
                conflictingReadOnly.append((name, "Permission denied: cannot rename file"))
            } catch {
                conflictingReadOnly.append((name, "OS error: \(error.localizedDescription)"))
            }
        }
        if !conflictingReadOnly.isEmpty {
            progress.close()
            StyledMessageDialog.showWarning(
                title: "Permission Error",
                message: "Cannot rename files because some existing files with conflicting names are read-only:\n\n"
                    + "\(Self.formatErrorList(conflictingReadOnly))\n\n"
                    + "These files would need to be moved to make room for the renamed files, but they cannot be renamed.\n\n"
                    + "Please check file permissions and try again."
            )
            return
        }

        let plan = RenamePrefixPlanner.buildEfficientRenamePlan(
            mappings: targetMappings,
            directory: targetDirectory,
            tempPrefix: tempPrefix,
            progress: { updateProgress($0, $1, $2, 50, 100) }
        )
        guard plan.operationCount > 0 else {
            progress.close()
            appState.status.show("No files need renaming")
            return
        }

        let renameMap = Dictionary(uniqueKeysWithValues: targetMappings.map { ($0.source, $0.target) })
        let totalOperations = plan.operationCount
        progress.setMaximum(totalOperations)
        progress.update(value: 0, label: "Renaming files...")

        // Capture metadata BEFORE rename (old paths disappear) so it can be migrated afterwards
        var preRenameMetadata: [String: MetadataCacheService.Entry] = [:]
        for (old, new) in renameMap where old != new && fm.fileExists(atPath: old) {
            if let entry = appState.metadataCache.rawEntry(for: old) {
                preRenameMetadata[old] = entry
            }
        }

        appState.beginSuppressDirectoryRefresh()

        // ---- Execute the three phases ----
        var completedRenames: [(current: String, original: String)] = []
        var renameErrors: [String] = []

        for (idx, op) in plan.phase0.enumerated() {
            progress.update(
                value: idx,
                label: "Moving conflicting file \(RenamePrefixPlanner.elideProgressFilename((op.source as NSString).lastPathComponent))..."
            )
            guard op.source != op.target else { continue }
            do {
                try fm.moveItem(atPath: op.source, toPath: op.target)
                completedRenames.append((op.target, op.source))
            } catch {
                renameErrors.append("Failed to move conflicting file \((op.source as NSString).lastPathComponent): \(error.localizedDescription)")
            }
        }
        for (idx, op) in plan.phase1.enumerated() {
            progress.update(
                value: plan.phase0.count + idx,
                label: "Renaming \(RenamePrefixPlanner.elideProgressFilename((op.source as NSString).lastPathComponent))..."
            )
            guard op.source != op.target else { continue }
            do {
                try fm.moveItem(atPath: op.source, toPath: op.target)
                completedRenames.append((op.target, op.source))
            } catch {
                renameErrors.append("Failed to rename \((op.source as NSString).lastPathComponent): \(error.localizedDescription)")
            }
        }
        for (idx, op) in plan.phase2.enumerated() {
            progress.update(
                value: plan.phase0.count + plan.phase1.count + idx,
                label: "Finalizing \(RenamePrefixPlanner.elideProgressFilename((op.target as NSString).lastPathComponent))..."
            )
            guard op.source != op.target else { continue }
            do {
                try fm.moveItem(atPath: op.source, toPath: op.target)
                if let position = completedRenames.firstIndex(where: { $0.current == op.source }) {
                    let original = completedRenames[position].original
                    completedRenames.remove(at: position)
                    completedRenames.append((op.target, original))
                }
            } catch {
                renameErrors.append(
                    "Failed to rename \((op.source as NSString).lastPathComponent) to \((op.target as NSString).lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
        progress.setMaximum(totalOperations + 1)
        progress.update(value: max(0, totalOperations - 1))

        if !renameErrors.isEmpty {
            var errorList = renameErrors.prefix(10).map { "  • \($0)" }.joined(separator: "\n")
            if renameErrors.count > 10 {
                errorList += "\n  ... and \(renameErrors.count - 10) more error(s)"
            }
            // Roll back completed renames (in reverse)
            var rollbackErrors: [String] = []
            for entry in completedRenames.reversed() where entry.current != entry.original {
                guard fm.fileExists(atPath: entry.current) else { continue }
                do {
                    try fm.moveItem(atPath: entry.current, toPath: entry.original)
                } catch {
                    rollbackErrors.append("Failed to rollback \((entry.current as NSString).lastPathComponent): \(error.localizedDescription)")
                }
            }
            var rollbackMessage = ""
            if !rollbackErrors.isEmpty {
                rollbackMessage = "\n\nRollback errors:\n" + rollbackErrors.prefix(5).map { "  • \($0)" }.joined(separator: "\n")
                if rollbackErrors.count > 5 {
                    rollbackMessage += "\n  ... and \(rollbackErrors.count - 5) more"
                }
            }
            progress.close()
            StyledMessageDialog.showCritical(
                title: "Rename Failed",
                message: "Some rename operations failed:\n\n\(errorList)\(rollbackMessage)"
            )
            appState.refreshDirectory()
            return
        }

        // ---- Migrate metadata cache from old paths to new paths ----
        progress.updateStatus(label: "Migrating metadata cache...")
        for (old, new) in renameMap where old != new {
            appState.metadataCache.invalidate(path: old)
            if let entry = preRenameMetadata[old], fm.fileExists(atPath: new) {
                appState.metadataCache.storeMigratedEntry(entry, for: new)
            }
        }
        let thumbnailCache = appState.thumbnailCache
        let oldPaths = renameMap.keys.filter { renameMap[$0] != $0 }
        Task { for path in oldPaths { await thumbnailCache.invalidate(for: path) } }

        // ---- Preserve lock status: rewrite .prsort with new names (locked first, in saved order) ----
        writePrsortAfterRename(
            directory: targetDirectory,
            imagesToRename: imagesToRename,
            targetMappings: targetMappings,
            lockedFilesOrder: lockedFilesOrder
        )

        // ---- Reset file dates on the NEW paths if requested ----
        var dateChangedPaths: [String] = []
        if dateChangeMode.changesDates {
            let now = Int(Date().timeIntervalSince1970)
            if sortMode == .order, let original = originalDisplayedOrder {
                var displayedIndex: [String: Int] = [:]
                for (idx, path) in original.enumerated() { displayedIndex[path] = idx }
                let total = original.count
                for mapping in targetMappings {
                    guard fm.fileExists(atPath: mapping.target), let idx = displayedIndex[mapping.source] else { continue }
                    let newMtime = dateChangeMode == .oldest ? now - (total - 1 - idx) : now - idx
                    if let old = RenamePrefixPlanner.currentMtime(mapping.target), abs(old - newMtime) > 1 {
                        RenamePrefixPlanner.setModificationTime(mapping.target, to: newMtime)
                        dateChangedPaths.append(mapping.target)
                    }
                    appState.metadataCache.updateModificationTime(path: mapping.target)
                }
            } else if sortMode == .date {
                let sorted = targetMappings.sorted {
                    RenamePrefixPlanner.sequenceNumber(of: $0.target, prefix: prefix)
                        < RenamePrefixPlanner.sequenceNumber(of: $1.target, prefix: prefix)
                }
                let total = sorted.count
                if total > 0 {
                    progress.updateStatus(label: "Updating file dates and metadata...")
                    for (idx, mapping) in sorted.enumerated() {
                        if idx % 10 == 0 {
                            progress.update(value: totalOperations - 1 + Int(Double(idx) / Double(total) * 0.5))
                        }
                        guard fm.fileExists(atPath: mapping.target) else { continue }
                        let seq = RenamePrefixPlanner.sequenceNumber(of: mapping.target, prefix: prefix)
                        let position = min(max(0, seq - startingNumber), total - 1)
                        let newMtime = dateChangeMode == .oldest ? now - (total - 1 - position) : now - position
                        if let old = RenamePrefixPlanner.currentMtime(mapping.target), abs(old - newMtime) > 1 {
                            RenamePrefixPlanner.setModificationTime(mapping.target, to: newMtime)
                            if let actual = RenamePrefixPlanner.currentMtime(mapping.target), abs(actual - newMtime) > 1 {
                                RenamePrefixPlanner.setModificationTime(mapping.target, to: newMtime)
                            }
                            dateChangedPaths.append(mapping.target)
                        }
                        appState.metadataCache.updateModificationTime(path: mapping.target)
                    }
                    progress.update(value: totalOperations - 1)
                }
            }
        }

        progress.update(value: totalOperations + 1, label: "Writing metadata to disk")
        appState.metadataCache.saveIfNeeded()
        progress.close()

        // ---- Update the active image to its new name ----
        let renameMapDict = renameMap.filter { $0.key != $0.value }
        var newActivePath: String?
        if let highlighted = context.highlightedPath, let mapped = renameMapDict[highlighted] {
            newActivePath = mapped
            if fm.fileExists(atPath: mapped) {
                appState.fileData.setCurrentImagePath(mapped)
            }
        }
        highlightFirstNonLockedAfterRename(directory: targetDirectory, renameMap: renameMapDict, preferredPath: newActivePath)

        // Deferred refresh (Python QTimer.singleShot(50, deferred_refresh))
        appState.beginSuppressDirectoryRefresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.deferredRefresh(
                directory: targetDirectory,
                sortMode: sortMode,
                targetMappings: targetMappings,
                renameMapDict: renameMapDict,
                displayedImages: displayedImages,
                originalDisplaySortMode: originalDisplaySortMode,
                newActivePath: newActivePath
            )
        }

        notifyThumbnailsChanged(dateChangedPaths)
        let renamedCount = actualRenames.count
        appState.status.show("Successfully renamed \(renamedCount) \(RenamePrefixPlanner.fileString(renamedCount))")
    }

    // MARK: - .prsort rewrite (lock preservation)

    private func writePrsortAfterRename(
        directory: String,
        imagesToRename: [String],
        targetMappings: [Mapping],
        lockedFilesOrder: [String]
    ) {
        let fm = FileManager.default
        var oldToNewName: [String: String] = [:]
        var oldToNewPath: [String: String] = [:]
        for mapping in targetMappings {
            oldToNewName[(mapping.source as NSString).lastPathComponent] = (mapping.target as NSString).lastPathComponent
            oldToNewPath[mapping.source] = mapping.target
        }

        let custom = PrsortIO.readCustomSort(in: directory)
        let lockedFiles = custom?.lockedFilenames ?? []

        // Locked filenames with new names, preserving .prsort order (the ONLY valid use of .prsort ordering)
        var newLockedOrdered: [String] = []
        var newLockedSet = Set<String>()
        for oldName in custom?.orderedFilenames ?? [] where lockedFiles.contains(oldName) {
            let newName = oldToNewName[oldName] ?? oldName
            if newLockedSet.insert(newName).inserted { newLockedOrdered.append(newName) }
        }
        for oldName in lockedFiles {
            let newName = oldToNewName[oldName] ?? oldName
            if newLockedSet.insert(newName).inserted { newLockedOrdered.append(newName) }
        }

        // Locked paths in their pre-rename order
        var lockedNewPaths: [String] = []
        var lockedNewSet = Set<String>()
        for oldLocked in lockedFilesOrder {
            if let newPath = oldToNewPath[oldLocked], fm.fileExists(atPath: newPath), lockedNewSet.insert(newPath).inserted {
                lockedNewPaths.append(newPath)
            }
        }
        if lockedNewPaths.isEmpty, !newLockedOrdered.isEmpty {
            var nameToNewPath: [String: String] = [:]
            for mapping in targetMappings {
                nameToNewPath[(mapping.target as NSString).lastPathComponent] = mapping.target
            }
            for newName in newLockedOrdered {
                if let newPath = nameToNewPath[newName], lockedNewSet.insert(newPath).inserted {
                    lockedNewPaths.append(newPath)
                }
            }
        }

        // Unlocked paths keep the rename order
        var unlockedNewPaths: [String] = []
        var unlockedNewSet = Set<String>()
        for oldPath in imagesToRename {
            let newPath = oldToNewPath[oldPath] ?? oldPath
            let newName = (newPath as NSString).lastPathComponent
            if !newLockedSet.contains(newName), !lockedNewSet.contains(newPath),
               fm.fileExists(atPath: newPath), unlockedNewSet.insert(newPath).inserted {
                unlockedNewPaths.append(newPath)
            }
        }
        for mapping in targetMappings where !lockedNewSet.contains(mapping.target) && !unlockedNewSet.contains(mapping.target) {
            if newLockedSet.contains((mapping.target as NSString).lastPathComponent) {
                lockedNewPaths.append(mapping.target)
                lockedNewSet.insert(mapping.target)
            } else {
                unlockedNewPaths.append(mapping.target)
                unlockedNewSet.insert(mapping.target)
            }
        }

        let filenames = (lockedNewPaths + unlockedNewPaths).map { ($0 as NSString).lastPathComponent }
        do {
            // Always write is_reversed=False so the exact order is preserved
            try PrsortIO.writeCustomSort(in: directory, filenames: filenames, isReversed: false, locked: newLockedSet)
        } catch {
            NSLog("WARNING: Failed to write .prsort file with lock status after rename: \(error)")
        }
    }

    // MARK: - Deferred refresh after rename

    private func deferredRefresh(
        directory: String,
        sortMode: RenamePrefixPlanner.SortMode,
        targetMappings: [Mapping],
        renameMapDict: [String: String],
        displayedImages: [String],
        originalDisplaySortMode: SortMode,
        newActivePath: String?
    ) {
        guard let appState else { return }
        let fm = FileManager.default
        appState.beginSuppressDirectoryRefresh()
        // Keep the multi-selection on the renamed files (new paths)
        let renamedNewPaths = Set(renameMapDict.values.filter { fm.fileExists(atPath: $0) })

        let hasLockedFiles = !PrsortIO.lockedFilenames(in: directory).isEmpty

        // "Sort by Current Order" only keeps the in-place list when the display itself is a custom
        // order (or locked files pin the order). For date/name/size displays the standard reload
        // below re-sorts, so renamed files (new names / new dates) move to their proper positions
        // while everything else stays put.
        if sortMode == .order, originalDisplaySortMode == .custom || hasLockedFiles {
            // Preserve the exact visual order of the WHOLE displayed list (not just the selection),
            // mapping renamed files to their new paths in place so unrenamed files never move.
            var finalOrder: [String] = []
            var seen = Set<String>()
            for old in displayedImages {
                let new = renameMapDict[old] ?? old
                if fm.fileExists(atPath: new), seen.insert(new).inserted { finalOrder.append(new) }
            }
            for mapping in targetMappings where fm.fileExists(atPath: mapping.target) && seen.insert(mapping.target).inserted {
                finalOrder.append(mapping.target)
            }
            // Include every image in the directory (locked files may not have been renamed)
            let pattern = appState.filterSettings.filterPattern
            let allInDir = DirectoryScanner.scanDirectory(
                at: directory,
                extensions: appState.config.imageExtensions,
                filterPattern: pattern
            )
            for path in allInDir where seen.insert(path).inserted {
                finalOrder.append(path)
            }
            if pattern != "*", !pattern.isEmpty {
                finalOrder = finalOrder.filter { DirectoryScanner.matchesGlob(($0 as NSString).lastPathComponent, pattern: pattern) }
            }
            // Locked files always at the top
            if !PrsortIO.lockedFilenames(in: directory).isEmpty {
                let (locked, unlocked) = PrsortIO.separateLockedUnlocked(finalOrder)
                finalOrder = locked + unlocked
            }

            appState.fileData.setDisplayedImages(finalOrder)
            selectRenamedFiles(renamedNewPaths)
            // displayed_images already has the NEW paths → no rename map
            highlightFirstNonLockedAfterRename(directory: directory, renameMap: nil, preferredPath: newActivePath)
            return
        }

        // "date" mode: reload from disk (the current display sort places renamed files by their new dates)
        let hasLocked = !PrsortIO.lockedFilenames(in: directory).isEmpty
        if hasLocked {
            // Custom sort ensures locked files stay on top (order written to .prsort above)
            appState.config.updateSetting("sort_mode", value: SortMode.custom.rawValue)
        }
        appState.selection.clearPreservingCurrentImage()
        appState.refreshDirectory()
        selectRenamedFiles(renamedNewPaths)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.highlightFirstNonLockedAfterRename(directory: directory, renameMap: renameMapDict, preferredPath: newActivePath)
            self?.selectRenamedFiles(renamedNewPaths)
        }
        if hasLocked { return }

        // Restore the display sort mode; CUSTOM becomes DATE (newest first)
        if originalDisplaySortMode == .custom {
            appState.applySortMode(.date, reversed: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.highlightFirstNonLockedAfterRename(directory: directory, renameMap: renameMapDict, preferredPath: nil)
            self?.selectRenamedFiles(renamedNewPaths)
        }
    }

    /// Re-select the renamed files under their new paths (the old selection held the old paths).
    private func selectRenamedFiles(_ newPaths: Set<String>) {
        guard let appState else { return }
        let displayed = Set(appState.fileData.displayedImages)
        let selectable = newPaths.intersection(displayed)
        guard !selectable.isEmpty else { return }
        appState.selection.selectedFiles = selectable
        appState.selection.emitSelectionChanged(highlightIndex: appState.fileData.currentIndex)
    }

    // MARK: - _highlight_first_non_locked_after_rename

    /// Highlight the renamed active image if it is not locked, otherwise the first non-locked item.
    private func highlightFirstNonLockedAfterRename(directory: String, renameMap: [String: String]?, preferredPath: String?) {
        guard let appState else { return }
        let locked = PrsortIO.lockedFilenames(in: directory)
        var displayed = appState.fileData.displayedImages

        // Only translate when displayed_images still holds old paths
        if let renameMap, !renameMap.isEmpty, displayed.contains(where: { renameMap[$0] != nil }) {
            displayed = displayed.map { old in
                let new = renameMap[old] ?? old
                return FileManager.default.fileExists(atPath: new) ? new : old
            }
        }
        guard !displayed.isEmpty else { return }

        func isLocked(_ path: String) -> Bool { locked.contains((path as NSString).lastPathComponent) }

        var target: String?
        if let preferredPath, displayed.contains(preferredPath), !isLocked(preferredPath) {
            target = preferredPath
        }
        if target == nil, let current = appState.fileData.currentImagePath, displayed.contains(current), !isLocked(current) {
            target = current
        }
        if target == nil {
            target = displayed.first { !isLocked($0) }
        }
        if target == nil {
            target = displayed.first
        }
        if let target {
            appState.fileData.setCurrentImagePath(target)
            appState.selection.emitSelectionChanged(highlightIndex: appState.fileData.currentIndex)
        }
    }

    // MARK: - Helpers

    /// Apply `(path, mtime)` changes and keep the metadata cache in sync. Returns the paths changed.
    @discardableResult
    private func applyDateChanges(_ changes: [(path: String, mtime: Int)]) -> [String] {
        guard let appState else { return [] }
        var changed: [String] = []
        for change in changes where FileManager.default.fileExists(atPath: change.path) {
            if RenamePrefixPlanner.setModificationTime(change.path, to: change.mtime) {
                appState.metadataCache.updateModificationTime(path: change.path)
                changed.append(change.path)
            }
        }
        return changed
    }

    /// Thumbnail cache keys include mtime, so date-only changes just need the views to reload.
    private func notifyThumbnailsChanged(_ paths: [String]) {
        guard let appState, !paths.isEmpty else { return }
        let cache = appState.thumbnailCache
        Task { for path in paths { await cache.invalidate(for: path) } }
        appState.thumbnailInvalidationGeneration += 1
        appState.eventBus.emit(.thumbnailsInvalidated, payload: .strings(paths))
    }

    private static func modificationTime(_ path: String) -> Double? {
        guard let date = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date else {
            return nil
        }
        return date.timeIntervalSince1970
    }

    /// Python error list formatting: first 10 entries, then "... and N more files".
    private static func formatErrorList(_ entries: [(String, String)]) -> String {
        var list = entries.prefix(10).map { "  • \($0.0): \($0.1)" }.joined(separator: "\n")
        if entries.count > 10 {
            let extra = entries.count - 10
            list += "\n  ... and \(extra) more \(RenamePrefixPlanner.fileString(extra))"
        }
        return list
    }
}
