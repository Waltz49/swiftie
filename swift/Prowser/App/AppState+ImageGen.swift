import AppKit
import SwiftUI

extension AppState {
    func scheduleProgressiveBrowseRefresh(_ path: String, forceEnterBrowse: Bool) {
        pendingProgressivePath = path
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
    }

    private func flushProgressiveBrowseRefresh() {
        progressiveRefreshTask?.cancel()
        progressiveRefreshTask = nil
        guard let path = pendingProgressivePath else { return }
        let forceEnterBrowse = pendingProgressiveForceEnterBrowse
        pendingProgressivePath = nil
        pendingProgressiveForceEnterBrowse = false
        Task { @MainActor in
            await flushProgressiveBrowseRefreshAsync(path: path, forceEnterBrowse: forceEnterBrowse)
        }
    }

    private func flushProgressiveBrowseRefreshAsync(path: String, forceEnterBrowse: Bool) async {
        guard FileManager.default.fileExists(atPath: path) else { return }
        await imageGen.writeProgressivePreviewExifIfNeeded(at: path)
        refreshProgressiveImageInBrowse(at: path, forceEnterBrowse: forceEnterBrowse)
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
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
        guard let current = fileData.currentDirectory,
              parent == URL(fileURLWithPath: current).standardizedFileURL.path else { return }
        guard !specificFilesActive else { return }

        if config.string(forKey: "sort_mode", default: "date") == SortMode.date.rawValue {
            config.updateSetting("sort_reversed", value: false)
        }

        beginSuppressDirectoryRefresh()
        ensureImageListedForBrowse(path: path)
        fileData.setCurrentImagePath(path)
        if let index = fileData.displayedImages.firstIndex(of: path) {
            fileData.setCurrentIndex(index)
        }
        DirectoryRefreshService.invalidateThumbnails(appState: self, paths: [path])
        reloadBrowseImageIfCurrent(path: path)

        if forceEnterBrowse {
            fileData.setViewMode(.browse)
        }
        imageGen.noteProgressiveBrowseOpened()
    }

    private func ensureImageListedForBrowse(path: String) {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        if directory != fileData.currentDirectory {
            loadDirectory(directory, saveHistory: false)
        } else if !fileData.displayedImages.contains(path) {
            DirectoryRefreshService.checkAndRefreshIfChanged(appState: self)
        }
        if !fileData.displayedImages.contains(path) {
            var images = fileData.displayedImages
            images.append(path)
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
           config.bool(forKey: "jobs_visible", default: true) {
            config.updateSetting("jobs_visible", value: false)
            noteSidebarLayoutChanged()
            return
        }
        showJobsPane()
    }

    func showJobsPane() {
        guard BundleCapabilities.imageGenUIEnabled else { return }
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

    func setJobsQueueSizeMode(_ mode: JobsQueueSizeMode, requireActive: Bool = false) {
        guard BundleCapabilities.imageGenUIEnabled else { return }
        if requireActive, !imageGen.isProcessing, imageGen.queue.jobs.isEmpty { return }
        applyJobsQueueSizeMode(mode, forceRefit: true)
    }

    func applyJobsQueueSizeMode(_ mode: JobsQueueSizeMode, forceRefit: Bool) {
        if jobsQueueSizeMode == mode, !forceRefit { return }
        if jobsQueueSizeMode != mode {
            // The card-stack measurement belongs to the previous mode (ALL stack vs ONE first
            // card); size from the fallback estimate until the new panel reports.
            measuredJobsCardStackHeight = 0
        }
        jobsQueueSizeMode = mode
        JobsQueueSizePersistence.save(mode, config: config)
        config.updateSetting("jobs_pane_compact", value: mode == .strip)
        syncJobsPaneGeometry()
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

    func syncJobsPaneGeometry() {
        scheduleJobsPaneGeometryRefit()
    }

    func growJobsPaneForActionBar(extra: CGFloat) {
        guard jobsDisplayMode == .pane, !isAdjustingJobsPaneGeometry else { return }
        rightSidebarSplit.growJobsPaneForActionBar(extraContentHeight: extra, appState: self)
    }

    func updateMeasuredActiveJobStripHeight(_ height: CGFloat) {
        let tolerance = SidebarPaneLayout.paneFitHeightTolerance(needed: height)
        guard abs(measuredActiveJobStripHeight - height) > tolerance else { return }
        measuredActiveJobStripHeight = height
        scheduleJobsPaneGeometryRefit()
    }

    func updateMeasuredJobsQueueGeometry(cardStackHeight: CGFloat) {
        let tolerance = SidebarPaneLayout.paneFitHeightTolerance(needed: cardStackHeight)
        guard abs(measuredJobsCardStackHeight - cardStackHeight) > tolerance else { return }
        measuredJobsCardStackHeight = cardStackHeight
        bumpImageGenUI()
        scheduleJobsPaneGeometryRefit()
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
        let prompt = initialPrompt
        if autoImportEXIF, prompt == nil {
            Task {
                let imported = await importPromptForActiveImageAsync()
                openImageGenDialog(
                    function: resolvedFunction,
                    replaceJobID: replaceJobID,
                    initialPrompt: imported,
                    autoImportEXIF: true,
                    autoGenerate: autoGenerate,
                    editSourcePaths: editSourcePaths
                )
            }
            return
        }
        imageGenDialogRequest = ImageGenDialogRequest(
            function: resolvedFunction,
            replaceJobID: replaceJobID,
            initialPrompt: prompt,
            autoImportEXIF: autoImportEXIF,
            autoGenerate: autoGenerate,
            editSourcePaths: editSourcePaths
        )
        let wasAlreadyOpen = showImageGenUnifiedDialog
        if wasAlreadyOpen {
            NotificationCenter.default.post(name: .prowserRaiseImageGenDialog, object: nil)
        } else {
            showImageGenUnifiedDialog = true
        }
        // Always bump so a closed-then-reopened dialog reloads (SwiftUI Window view may persist).
        imageGenDialogReloadToken += 1
    }

    func closeImageGenUnifiedDialog() {
        showImageGenUnifiedDialog = false
    }

    func openFastImageGenDialog() {
        let action = config.string(forKey: "imagegen_fast_open_action", default: "from_text")
        Task {
            let prompt = await importPromptForActiveImageAsync()
            if action == "edit_image" {
                openImageGenDialog(function: "edit", initialPrompt: prompt, autoImportEXIF: true)
            } else {
                openImageGenDialog(function: "create", initialPrompt: prompt, autoImportEXIF: true)
            }
        }
    }

    func editActiveQueueJob() {
        let rows = imageGen.queueSnapshot()
        guard let active = rows.first(where: { $0.isActive }) ?? rows.first else { return }
        openImageGenDialog(function: nil, replaceJobID: active.jobID)
    }

    func openGeneratedImageInBrowse(path: String) {
        showProwserGeneratedImage(at: path)
    }

    func confirmCancelGeneration() {
        guard imageGen.isRunning() else { return }
        if StyledMessageDialog.showConfirm(
            title: "Cancel job?",
            message: "Cancel the running job?",
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
        let prompt = row.isActive ? "Cancel the running job?" : "Remove this job from the queue?"
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
        if imageGen.quitGateAllowsImmediateTerminate() {
            return true
        }
        let stripHost = NSHostingController(
            rootView: ActiveJobStripView().environment(self)
        )
        stripHost.view.frame = NSRect(x: 0, y: 0, width: 360, height: 80)
        Task { await imageGen.refreshActiveStripView() }

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
