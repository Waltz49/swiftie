import AppKit
import ImageIO
import SwiftUI

extension AppState {
    func scheduleProgressiveBrowseRefresh(
        _ path: String,
        forceEnterBrowse: Bool,
        completedStep: Int,
        stepTotal: Int
    ) {
        pendingProgressivePath = path
        pendingProgressiveCompletedStep = completedStep
        pendingProgressiveStepTotal = stepTotal
        pendingProgressiveForceEnterBrowse = pendingProgressiveForceEnterBrowse || forceEnterBrowse
        if forceEnterBrowse {
            flushProgressiveBrowseRefresh()
            return
        }
        if progressiveRefreshTask != nil { return }
        progressiveRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled else { return }
            flushProgressiveBrowseRefresh()
        }
    }

    private func cancelProgressiveBrowseRefresh() {
        progressiveRefreshTask?.cancel()
        progressiveRefreshTask = nil
        pendingProgressivePath = nil
        pendingProgressiveForceEnterBrowse = false
        pendingProgressiveCompletedStep = 0
        pendingProgressiveStepTotal = 0
    }

    private func flushProgressiveBrowseRefresh() {
        progressiveRefreshTask?.cancel()
        progressiveRefreshTask = nil
        guard let path = pendingProgressivePath else { return }
        let forceEnterBrowse = pendingProgressiveForceEnterBrowse
        let completedStep = pendingProgressiveCompletedStep
        let stepTotal = pendingProgressiveStepTotal
        pendingProgressivePath = nil
        pendingProgressiveForceEnterBrowse = false
        pendingProgressiveCompletedStep = 0
        pendingProgressiveStepTotal = 0
        Task { @MainActor in
            await flushProgressiveBrowseRefreshAsync(
                path: path,
                forceEnterBrowse: forceEnterBrowse,
                completedStep: completedStep,
                stepTotal: stepTotal
            )
        }
    }

    private func flushProgressiveBrowseRefreshAsync(
        path: String,
        forceEnterBrowse: Bool,
        completedStep: Int,
        stepTotal: Int
    ) async {
        // Python emits progress on stderr right after atomic_replace; the Swift worker subprocess
        // can deliver the message before the preview file is visible here (especially on first preview).
        await Task.yield()
        var readablePath: String?
        for _ in 0..<40 {
            if Task.isCancelled { return }
            if FileManager.default.fileExists(atPath: path), progressivePreviewFileIsReadable(path) {
                readablePath = path
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let readablePath else { return }
        await imageGen.writeProgressivePreviewExifIfNeeded(
            at: path,
            completedStep: completedStep > 0 ? completedStep : nil,
            totalSteps: stepTotal > 0 ? stepTotal : nil
        )
        refreshProgressiveImageInBrowse(at: readablePath, forceEnterBrowse: forceEnterBrowse)
    }

    /// Port of Python ``_progressive_image_readable`` (skip truncated/incomplete image files).
    private func progressivePreviewFileIsReadable(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let rasterExts = ["png", "webp", "jpg", "jpeg", "tif", "tiff"]
        guard rasterExts.contains(ext) else { return true }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
            return false
        }
        return CGImageSourceGetStatus(source) == .statusComplete
    }

    /// Show a Prowser-generated output in browse immediately (port of Python ``_open_in_browse``).
    func showProwserGeneratedImage(at path: String) {
        guard !path.isEmpty else { return }
        prowserGeneratedImageOpenTask?.cancel()
        prowserGeneratedImageOpenTask = Task { @MainActor in
            cancelProgressiveBrowseRefresh()
            imageGen.resetProgressiveBrowseOpened()
            // Defer one tick (Python QTimer.singleShot(0)) then retry until the file exists.
            await Task.yield()
            for _ in 0..<40 {
                if Task.isCancelled { return }
                if FileManager.default.fileExists(atPath: path) {
                    // Stack the folder we are leaving. Esc from this browse stays in the
                    // output folder; the next Esc returns to the stacked folder.
                    displaceCurrentLevelIfOpeningNewDirectory(path)
                    ensureImageListedForBrowse(path: path)
                    openImageInBrowse(path: path, saveHistory: false)
                    clearBrowseReturnState()
                    reloadBrowseImageIfCurrent(path: path)
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func refreshProgressiveImageInBrowse(at path: String, forceEnterBrowse: Bool) {
        guard imageGen.showProgressiveImages else { return }
        guard !isSlideshowActive else { return }
        guard FileManager.default.fileExists(atPath: path) else { return }

        let inPlace = tryInPlaceProgressiveRefresh(at: path)
        let wantBrowse = forceEnterBrowse || !imageGen.progressiveBrowseWasOpened
        if inPlace {
            if !wantBrowse { return }
            if fileData.currentViewMode == .browse { return }
        }

        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
        let currentParent = fileData.currentDirectory.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        let needsBrowseLevel = currentParent != parent || specificFilesActive

        if needsBrowseLevel {
            if forceEnterBrowse, currentParent != parent {
                displaceCurrentLevelIfOpeningNewDirectory(path)
            }
            setSpecificFilesActive(false)
            openImageInBrowse(path: path, saveHistory: false)
        } else {
            ensureImageListedForBrowse(path: path)
            fileData.setCurrentImagePath(path)
            if let index = FileDataModel.indexOfPath(path, in: fileData.displayedImages) {
                fileData.setCurrentIndex(index)
            }
            if forceEnterBrowse {
                fileData.setViewMode(.browse)
            }
        }
        DirectoryRefreshService.invalidateThumbnails(appState: self, paths: [path])
        reloadBrowseImageIfCurrent(path: path)
        imageGen.noteProgressiveBrowseOpened()
    }

    /// Python ``_try_in_place_progressive_refresh`` — thumbnail/list/browse pixels + directory listing sync.
    @discardableResult
    private func tryInPlaceProgressiveRefresh(at outputPath: String) -> Bool {
        let mode = fileData.currentViewMode
        guard mode == .thumbnail || mode == .list || mode == .browse else { return false }
        guard let normalized = FileDataModel.normalizePath(outputPath) else { return false }

        let listedPath = fileData.displayedImages.first { FileDataModel.pathsReferToSameFile($0, normalized) }
        let inCurrentDirectory = fileData.currentDirectory.map {
            FileDataModel.pathIsInDirectory(file: normalized, directory: $0)
        } ?? false

        if !inCurrentDirectory, listedPath == nil { return false }

        if listedPath == nil, imageGen.shouldEmitProgressiveListSync(for: normalized) {
            imageGen.noteProgressiveListSyncOutputPath(normalized)
            let syncDirectory = inCurrentDirectory ? (fileData.currentDirectory ?? parentDirectory(of: normalized)) : parentDirectory(of: normalized)
            if let syncDirectory {
                eventBus.emit(.filesChangedOnDisk, payload: .string(syncDirectory))
            }
        }

        switch mode {
        case .thumbnail, .list:
            if listedPath != nil {
                DirectoryRefreshService.refreshDisplayedFileIfListed(appState: self, path: normalized)
            } else {
                DirectoryRefreshService.invalidateThumbnails(appState: self, paths: [normalized])
            }
            thumbnailGridHost?.startBackgroundThumbnailLoadingIfNeeded()
            return true
        case .browse:
            guard DirectoryRefreshService.refreshDisplayedFileIfListed(appState: self, path: normalized) else {
                return false
            }
            guard let current = fileData.currentImagePath,
                  FileDataModel.pathsReferToSameFile(current, normalized) else { return false }
            reloadBrowseImageIfCurrent(path: normalized)
            return true
        default:
            return false
        }
    }

    private func parentDirectory(of path: String) -> String? {
        FileDataModel.parentDirectory(of: path)
    }

    private func ensureImageListedForBrowse(path: String) {
        guard let normalized = FileDataModel.normalizePath(path) else { return }
        let directory = URL(fileURLWithPath: normalized).deletingLastPathComponent().path
        if directory != fileData.currentDirectory {
            loadDirectory(directory, saveHistory: false)
        } else if FileDataModel.indexOfPath(normalized, in: fileData.displayedImages) == nil {
            DirectoryRefreshService.checkAndRefreshIfChanged(appState: self)
        }
        if FileDataModel.indexOfPath(normalized, in: fileData.displayedImages) == nil {
            var images = fileData.displayedImages
            images.append(normalized)
            let options = SortingService.Options.from(config: config)
            fileData.setDisplayedImages(
                SortingService.sorted(images, options: options, metadataCache: metadataCache)
            )
        }
    }

    private var isSlideshowActive: Bool {
        switch fileData.currentViewMode {
        case .slideshow, .slideshow2, .slideshow3:
            return true
        default:
            return false
        }
    }
    func toggleJobsPane() {
        guard BundleCapabilities.imageGenUIEnabled else { return }
        if jobsDisplayMode == .pane,
           config.bool(forKey: "jobs_visible", default: true),
           rightSidebarColumnVisible {
            config.updateSetting("jobs_visible", value: false)
            noteSidebarLayoutChanged()
            return
        }
        showJobsPane()
    }

    func showJobsPane() {
        guard BundleCapabilities.imageGenUIEnabled else { return }
        clearChromeSuppression()
        showFloatingJobsPanel = false
        jobsDisplayMode = .pane
        config.updateSetting("jobs_display_mode", value: JobsDisplayMode.pane.rawValue)
        config.updateSetting("jobs_visible", value: true)
        revealSidebarColumn(.right)
        noteSidebarLayoutChanged()
        syncJobsPaneGeometry()
    }

    func showJobsPanel() {
        guard BundleCapabilities.imageGenUIEnabled else { return }
        config.updateSetting("jobs_visible", value: false)
        jobsDisplayMode = .panel
        config.updateSetting("jobs_display_mode", value: JobsDisplayMode.panel.rawValue)
        showFloatingJobsPanel = true
        noteSidebarLayoutChanged()
    }

    func hideJobsPanel() {
        showFloatingJobsPanel = false
    }

    func toggleJobsPanel() {
        guard BundleCapabilities.imageGenUIEnabled else { return }
        if showFloatingJobsPanel {
            hideJobsPanel()
            return
        }
        showJobsPanel()
    }

    func cycleActiveJobsSurfaceSize() {
        guard BundleCapabilities.imageGenUIEnabled else { return }
        if showFloatingJobsPanel {
            cycleJobsQueueSizeMode()
            return
        }
        if jobsDisplayMode == .pane {
            rightSidebarSplit.cycleJobsPaneSize(appState: self)
        }
    }

    @discardableResult
    func setJobsQueueSizeMode(_ mode: JobsQueueSizeMode, requireActive: Bool = false) -> Bool {
        guard BundleCapabilities.imageGenUIEnabled else { return false }
        if requireActive, !imageGen.isProcessing, imageGen.queue.jobs.isEmpty { return false }
        ensureJobsSurfaceVisible()
        jobsSurfaceExactSnapPasses = 4
        applyJobsQueueSizeMode(mode, forceRefit: true)
        return true
    }

    /// Show the last-used jobs surface when both the pane and the floating panel are hidden.
    func ensureJobsSurfaceVisible() {
        if showFloatingJobsPanel { return }
        let paneVisible = jobsDisplayMode == .pane
            && config.bool(forKey: "jobs_visible", default: true)
        if paneVisible { return }
        if jobsDisplayMode == .panel {
            showJobsPanel()
        } else {
            showJobsPane()
        }
    }

    func applyJobsQueueSizeMode(_ mode: JobsQueueSizeMode, forceRefit: Bool) {
        if jobsQueueSizeMode == mode, !forceRefit { return }
        if jobsQueueSizeMode != mode {
            // The card-stack measurement belongs to the previous mode (ALL stack vs ONE first
            // card); size from the fallback estimate until the new panel reports.
            measuredJobsCardStackHeight = 0
            jobsPaneAllMultiHeightPinned = false
        }
        jobsQueueSizeMode = mode
        JobsQueueSizePersistence.save(mode, config: config)
        config.updateSetting("jobs_pane_compact", value: mode == .strip)
        syncJobsPaneGeometry(forceRefit: forceRefit)
    }

    func cycleJobsQueueSizeMode() {
        applyJobsQueueSizeMode(jobsQueueSizeMode.next(), forceRefit: true)
    }

    func bumpImageGenUI() {
        imageGenUIRevision += 1
    }

    /// Port of `JobQueuePanelWidget.should_shrink_wrap_client()`.
    func shouldShrinkWrapJobsClient() -> Bool {
        if imageGen.isProcessing || imageGen.cooldownSecondsRemaining > 0 {
            return false
        }
        if !imageGen.queue.jobs.isEmpty {
            return false
        }
        return imageGen.queueSnapshot().isEmpty
    }

    func syncJobsPaneGeometry(forceRefit: Bool = false) {
        if forceRefit {
            jobsPaneGeometryForceRefit = true
        }
        scheduleJobsPaneGeometryRefit()
    }

    func growJobsPaneForActionBar(extra: CGFloat) {
        guard jobsDisplayMode == .pane, !isAdjustingJobsPaneGeometry else { return }
        rightSidebarSplit.growJobsPaneForActionBar(extraContentHeight: extra, appState: self)
    }

    func updateMeasuredActiveJobStripHeight(_ height: CGFloat) {
        let tolerance = SidebarPaneLayout.paneFitHeightTolerance(needed: height)
        let structureKey = imageGen.activeStripView.structureKey()
        var refitTolerance = tolerance
        if imageGen.isProcessing {
            if structureKey == lastStripHeightRefitStructureKey {
                refitTolerance = max(tolerance, 12)
            } else {
                lastStripHeightRefitStructureKey = structureKey
            }
        } else {
            lastStripHeightRefitStructureKey = nil
        }
        guard abs(measuredActiveJobStripHeight - height) > refitTolerance else { return }
        measuredActiveJobStripHeight = height
        guard shouldScheduleJobsPaneRefitForContentChange() else { return }
        scheduleJobsPaneGeometryRefit()
    }

    func updateMeasuredJobsQueueGeometry(cardStackHeight: CGFloat) {
        let tolerance = SidebarPaneLayout.paneFitHeightTolerance(needed: cardStackHeight)
        guard abs(measuredJobsCardStackHeight - cardStackHeight) > tolerance else { return }
        measuredJobsCardStackHeight = cardStackHeight
        guard shouldScheduleJobsPaneRefitForContentChange(allowGrowWhenAllMultiPinned: true) else { return }
        scheduleJobsPaneGeometryRefit()
    }

    /// Port of ``ensure_jobs_pane_fits_content`` gating when ``JOBS_PANE_AUTO_RESIZE_ON_JOB_CHANGE`` is false.
    func shouldScheduleJobsPaneRefitForContentChange(allowGrowWhenAllMultiPinned: Bool = false) -> Bool {
        guard jobsDisplayMode == .pane else { return false }
        if jobsQueueSizeMode == .all, imageGen.queue.jobs.count > 1, jobsPaneAllMultiHeightPinned {
            guard allowGrowWhenAllMultiPinned else { return false }
            refreshJobsPaneLiveMeasurements()
            let target = jobsPaneTargetPaneHeight()
            let current = rightSidebarSplit.sizes[2]
            let tolerance = SidebarPaneLayout.paneFitHeightTolerance(needed: target)
            return target > current + tolerance
        }
        return true
    }

    func beginJobsPaneGeometryAdjustment() {
        isAdjustingJobsPaneGeometry = true
    }

    func endJobsPaneGeometryAdjustment() {
        isAdjustingJobsPaneGeometry = false
        if jobsPaneRefitDeferred {
            jobsPaneRefitDeferred = false
            scheduleJobsPaneGeometryRefit()
        }
    }
    /// Reopen the unified dialog for a queue job (Python ``job_queue_edit_row`` / ``open_imagegen_dialog_from_job``).
    func openImageGenDialogFromQueueJob(jobID: String) {
        guard let job = imageGen.jobForQueueEditor(jobID: jobID) else { return }
        let tempRoot = config.temporaryFilesDirectory.path
        if job.function == "edit" {
            let readable = ImageGenExifReferences.resolveSourceImagePaths(job.values)
                .filter { FileManager.default.isReadableFile(atPath: $0) }
            if readable.isEmpty {
                StyledMessageDialog.showWarning(
                    title: "Edit",
                    message: "Source image files for this job are no longer available."
                )
                return
            }
            let restored = ImageGenJobDialogRestore.editSourcePaths(from: job.values, tempRoot: tempRoot)
            let paths = restored.isEmpty ? readable : restored
            openImageGenDialog(function: job.function, replaceJobID: jobID, editSourcePaths: paths)
            return
        }
        if job.function == "expand" {
            let readable = ImageGenExifReferences.resolveSourceImagePaths(job.values)
                .filter { FileManager.default.isReadableFile(atPath: $0) }
            if readable.isEmpty {
                StyledMessageDialog.showWarning(
                    title: "Expand",
                    message: "Source image for this job is no longer available."
                )
                return
            }
        }
        openImageGenDialog(function: job.function, replaceJobID: jobID)
    }

    private func presentImageGenUnifiedDialogWindow() {
        if SceneWindowChrome.bringImageGenUnifiedWindowToFront() {
            NotificationCenter.default.post(name: .prowserRaiseImageGenDialog, object: nil)
            return
        }
        NotificationCenter.default.post(name: .prowserPresentImageGenUnifiedWindow, object: nil)
    }

    func openImageGenDialog(
        function: String? = nil,
        replaceJobID: String? = nil,
        initialPrompt: String? = nil,
        autoImportEXIF: Bool = false,
        autoGenerate: Bool = false,
        editSourcePaths: [String] = []
    ) {
        guard imageGen.isEnabled else {
            status.show(imageGen.unavailableStatusMessage())
            return
        }
        let session = ImageGenSessionState()
        let resolvedFunction = function ?? session.lastFunction(config: config)
        if replaceJobID == nil,
           !ImageGenFunctionPrerequisites.validate(
               function: resolvedFunction,
               appState: self,
               editSourcePaths: editSourcePaths
           ) {
            return
        }
        let newRequest = ImageGenDialogRequest(
            function: resolvedFunction,
            replaceJobID: replaceJobID,
            initialPrompt: initialPrompt,
            autoImportEXIF: autoImportEXIF,
            autoGenerate: autoGenerate,
            editSourcePaths: editSourcePaths
        )
        let wasAlreadyOpen = showImageGenUnifiedDialog
        let requestUnchanged = newRequest == imageGenDialogRequest
        imageGenDialogRequest = newRequest
        if wasAlreadyOpen {
            let refreshActiveSource = replaceJobID == nil
                && (resolvedFunction == "infill" || resolvedFunction == "expand")
            if requestUnchanged, !refreshActiveSource {
                presentImageGenUnifiedDialogWindow()
                return
            }
            imageGenDialogApplyToken += 1
            presentImageGenUnifiedDialogWindow()
            return
        }
        showImageGenUnifiedDialog = true
        // Closed-then-reopened (or first open): full load (SwiftUI Window view may persist).
        imageGenDialogReloadToken += 1
        // First open: MainWindowView `onChange(of: showImageGenUnifiedDialog)` calls `openWindow`.
    }

    func closeImageGenUnifiedDialog() {
        showImageGenUnifiedDialog = false
    }

    /// Open a persisted Image Generation screen, primed from the active image.
    /// EXIF Import Rest intentionally preserves the dialog's stored size controls.
    func openImageGenDialogFromActiveImage(function: String? = nil) {
        let resolvedFunction = function ?? ImageGenSessionState().lastFunction(config: config)
        Task { @MainActor in
            let prompt = await importPromptForActiveImageAsync()
            openImageGenDialog(
                function: resolvedFunction,
                initialPrompt: prompt,
                autoImportEXIF: true
            )
        }
    }

    func openFastImageGenDialog() {
        openImageGenDialogFromActiveImage()
    }

    func editActiveQueueJob() {
        guard let activeJobID = imageGen.activeJobID else { return }
        openImageGenDialogFromQueueJob(jobID: activeJobID)
    }

    func openGeneratedImageInBrowse(path: String) {
        showProwserGeneratedImage(at: path)
    }

    func confirmCancelGeneration() {
        guard imageGen.isRunning() else { return }
        let jobNumber = imageGen.activeJobID.flatMap { imageGen.jobNumberForDisplay(jobID: $0) }
        if StyledMessageDialog.showConfirm(
            title: "Cancel job?",
            message: ImageGenJobNumber.cancelConfirmMessage(isActive: true, jobNumber: jobNumber),
            confirmTitle: "Cancel Job",
            cancelTitle: "Keep Running",
            defaultCancel: true
        ) {
            imageGen.cancelActiveJob()
        }
    }

    func confirmCancelJob(id: String, cascade: Bool) {
        if cascade {
            imageGen.cancelJob(id: id, cascade: true)
            return
        }
        let rows = imageGen.queueSnapshot()
        guard let row = rows.first(where: { $0.jobID == id }) else { return }
        let prompt = ImageGenJobNumber.cancelConfirmMessage(
            isActive: row.isActive,
            jobNumber: imageGen.jobNumberForDisplay(jobID: id)
        )
        let confirmTitle = row.isActive ? "Cancel Job" : "Remove"
        let keepTitle = row.isActive ? "Keep Running" : "Keep"
        let parent = BrowserWindowIdentity.resolveMainBrowserWindow()
        if StyledMessageDialog.showConfirm(
            title: "Cancel job?",
            message: prompt,
            confirmTitle: confirmTitle,
            cancelTitle: keepTitle,
            defaultCancel: true,
            parentWindow: parent
        ) {
            imageGen.cancelJob(id: id)
        }
    }

    func confirmQuitIfRunning() -> Bool {
        if shouldSkipQuitPromptBecauseAlreadyConfirmed() {
            return true
        }
        if imageGen.quitGateAllowsImmediateTerminate() {
            return true
        }
        let stripHost = NSHostingController(
            rootView: ActiveJobStripView().environment(self)
        )
        stripHost.view.frame = NSRect(x: 0, y: 0, width: 360, height: 80)
        imageGen.prepareQuitConfirmationStrip()

        let parentWindow = BrowserWindowIdentity.resolveMainBrowserWindow()
        let choice = StyledMessageDialog.present(
            title: "AI task running",
            message: "Image generation or an AI caption is in progress.\nQuit anyway?",
            style: .warning,
            buttons: [
                StyledMessageDialog.Button("No", role: .dismissive),
                StyledMessageDialog.Button("Quit anyway"),
                StyledMessageDialog.Button("Wait and quit"),
            ],
            defaultButtonIndex: 0,
            escapeButtonIndex: 0,
            accessoryView: stripHost.view,
            parentWindow: parentWindow
        )
        switch choice {
        case 1:
            imageGen.prepareForShutdown()
            return true
        case 2:
            imageGen.setDeferredQuitAppState(self)
            imageGen.beginQuitAfterCurrentWorker()
            return false
        default:
            return false
        }
    }

    func setJobsToolbarVisible(_ visible: Bool) {
        guard jobsToolbarVisible != visible else { return }
        jobsToolbarVisible = visible
        config.updateSetting("jobs_show_toolbar", value: visible)
        config.applySettingsChange(emit: eventBus)
        DispatchQueue.main.async { [weak self] in
            self?.syncJobsPaneGeometry()
        }
    }

    func setJobsPanelAlwaysOnTop(_ enabled: Bool) {
        guard jobsPanelAlwaysOnTop != enabled else { return }
        jobsPanelAlwaysOnTop = enabled
        var imagegen = config.rawSettings()["imagegen"] as? [String: Any] ?? [:]
        imagegen["job_queue_always_on_top"] = enabled
        config.updateSetting("imagegen", value: imagegen)
        config.applySettingsChange(emit: eventBus)
        SceneWindowChrome.applyJobsPanelAlwaysOnTop(enabled)
    }

}
