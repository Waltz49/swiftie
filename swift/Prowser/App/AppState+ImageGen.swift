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
        let isFinalStep = completedStep > 0 && stepTotal > 0 && completedStep >= stepTotal
        refreshProgressiveImageInBrowse(
            at: readablePath,
            forceEnterBrowse: forceEnterBrowse,
            isFinalStep: isFinalStep
        )
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

    private func refreshProgressiveImageInBrowse(
        at path: String,
        forceEnterBrowse: Bool,
        isFinalStep: Bool
    ) {
        guard imageGen.showProgressiveImages else { return }
        guard !isSlideshowActive else { return }
        guard FileManager.default.fileExists(atPath: path) else { return }

        let inPlace = tryInPlaceProgressiveRefresh(at: path)
        if imageGenUnifiedDialogIsVisible && !isFinalStep {
            return
        }
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
        if !inPlace {
            let listed = listedDisplayedPath(for: path)
            DirectoryRefreshService.invalidateThumbnails(appState: self, paths: [listed])
        }
        reloadBrowseImageIfCurrent(path: path)
        imageGen.noteProgressiveBrowseOpened()
    }

    private func listedDisplayedPath(for path: String) -> String {
        guard let normalized = FileDataModel.normalizePath(path) else { return path }
        if let listed = fileData.displayedImages.first(where: {
            FileDataModel.pathsReferToSameFile($0, normalized)
        }) {
            return listed
        }
        return normalized
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

        let refreshPath = listedPath ?? normalized
        switch mode {
        case .thumbnail, .list:
            if listedPath != nil {
                DirectoryRefreshService.refreshDisplayedFileIfListed(appState: self, path: refreshPath)
            } else {
                DirectoryRefreshService.invalidateThumbnails(appState: self, paths: [refreshPath])
            }
            thumbnailGridHost?.startBackgroundThumbnailLoadingIfNeeded()
            return true
        case .browse:
            guard DirectoryRefreshService.refreshDisplayedFileIfListed(appState: self, path: refreshPath) else {
                return false
            }
            guard let current = fileData.currentImagePath,
                  FileDataModel.pathsReferToSameFile(current, normalized) else { return false }
            reloadBrowseImageIfCurrent(path: refreshPath)
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

    /// ⌘\\ — restore persisted jobs height, or autosize once and commit as saved until the user drags.
    @discardableResult
    func handleCommandBackslashJobsPaneHeight() -> Bool {
        guard BundleCapabilities.imageGenUIEnabled else { return false }
        guard jobsDisplayMode == .pane else { return false }
        // #region agent log
        DebugAgentLog.write(
            hypothesisId: "F",
            location: "AppState+ImageGen.handleCommandBackslashJobsPaneHeight",
            message: "cmd_backslash_invoked",
            data: [
                "mode": jobsQueueSizeMode.rawValue,
                "splitter2": rightSidebarSplit.sizes[2],
                "dedicated": jobsPaneAllMultijobSavedHeight() ?? -1,
                "established": JobsQueueSizePersistence.loadAllMultijobHeightEstablished(config: config),
                "locked": jobsPaneUserHeldAllMultijobHeight(),
            ]
        )
        // #endregion
        ensureJobsSurfaceVisible()
        if restoreEstablishedAllMultijobHeightIfPossible() {
            return true
        }
        if jobsPaneAllMultijobHeightScenario() {
            establishJobsPaneAllMultijobHeightViaAutosize()
            return true
        }
        setJobsPaneUserAllMultijobHeightLocked(false)
        jobsSurfaceExactSnapPasses = 4
        applyJobsQueueSizeMode(jobsQueueSizeMode, forceRefit: true)
        return true
    }

    /// Pin / ⌘\\ restore when user committed a saved ALL height (drag or first ⌘\\ autosize).
    func jobsPaneSavedHeightPinActive() -> Bool {
        guard jobsDisplayMode == .pane else { return false }
        guard jobsQueueSizeMode == .all else { return false }
        guard !shouldShrinkWrapJobsClient() else { return false }
        guard !rightSidebarSplit.jobsIsSoleVisiblePane(appState: self) else { return false }
        guard JobsQueueSizePersistence.loadAllMultijobHeightEstablished(config: config) else { return false }
        guard jobsPaneAllMultijobSavedHeight() != nil else { return false }
        return jobsPaneUserSplitterSized
            || JobsQueueSizePersistence.loadUserAllMultijobHeightLocked(config: config)
    }

    @discardableResult
    private func restoreEstablishedAllMultijobHeightIfPossible() -> Bool {
        guard !shouldShrinkWrapJobsClient() else { return false }
        guard !rightSidebarSplit.jobsIsSoleVisiblePane(appState: self) else { return false }
        guard JobsQueueSizePersistence.loadAllMultijobHeightEstablished(config: config) else { return false }
        guard let target = jobsPaneAllMultijobSavedHeight() else { return false }
        let modeBefore = jobsQueueSizeMode
        let sizeBefore = rightSidebarSplit.sizes[2]
        if jobsQueueSizeMode != .all {
            applyJobsQueueSizeMode(
                .all,
                forceRefit: false,
                retainUserHeightEnteringAll: false,
                preserveAllMultijobSavedHeight: true
            )
        }
        // #region agent log
        DebugAgentLog.write(
            hypothesisId: "E",
            location: "AppState+ImageGen.restoreEstablishedAllMultijobHeightIfPossible",
            message: "cmd_backslash_restore_path",
            data: [
                "modeBefore": modeBefore.rawValue,
                "modeAfter": jobsQueueSizeMode.rawValue,
                "targetDedicated": target,
                "splitterBeforeSwitch": sizeBefore,
                "splitterAfterSwitch": rightSidebarSplit.sizes[2],
            ]
        )
        // #endregion
        setJobsPaneUserAllMultijobHeightLocked(true)
        rightSidebarSplit.restoreJobsPaneToSavedAllMultijobHeight(appState: self, height: target)
        sidebarLayoutRevision += 1
        return true
    }

    func jobsPaneAllMultijobHeightScenario() -> Bool {
        guard jobsQueueSizeMode == .all else { return false }
        guard visibleJobsQueueRowCount() > 1 else { return false }
        guard !shouldShrinkWrapJobsClient() else { return false }
        return !rightSidebarSplit.jobsIsSoleVisiblePane(appState: self)
    }

    func markJobsPaneAllMultijobHeightEstablished() {
        JobsQueueSizePersistence.saveAllMultijobHeightEstablished(true, config: config)
    }

    func commitJobsPaneAllMultijobSavedHeight(_ height: CGFloat) {
        JobsQueueSizePersistence.saveAllMultijobSavedHeight(height, config: config)
        markJobsPaneAllMultijobHeightEstablished()
    }

    func jobsPaneAllMultijobSavedHeight() -> CGFloat? {
        if let dedicated = JobsQueueSizePersistence.loadAllMultijobSavedHeight(config: config) {
            return dedicated
        }
        guard JobsQueueSizePersistence.loadAllMultijobHeightEstablished(config: config) else { return nil }
        let legacy = rightSidebarSplit.savedSizes[2]
        guard legacy > SidebarPaneLayout.headerHeight else { return nil }
        JobsQueueSizePersistence.saveAllMultijobSavedHeight(legacy, config: config)
        return legacy
    }

    private func establishJobsPaneAllMultijobHeightViaAutosize() {
        setJobsPaneUserAllMultijobHeightLocked(false)
        rightSidebarSplit.ensureJobsPaneFitsContent(appState: self, forceRefit: true)
        commitJobsPaneAllMultijobSavedHeight(rightSidebarSplit.sizes[2])
        setJobsPaneUserAllMultijobHeightLocked(true)
    }

    @discardableResult
    func setJobsQueueSizeMode(_ mode: JobsQueueSizeMode, requireActive: Bool = false) -> Bool {
        guard BundleCapabilities.imageGenUIEnabled else { return false }
        if requireActive, !imageGen.isProcessing, imageGen.queue.jobs.isEmpty { return false }
        ensureJobsSurfaceVisible()
        // ⌥\ ALL: keep persisted splitter height; titlebar double-click uses ``cycleJobsPaneSize`` instead.
        if mode == .all {
            applyJobsQueueSizeMode(mode, forceRefit: false, retainUserHeightEnteringAll: true)
        } else {
            jobsSurfaceExactSnapPasses = 4
            applyJobsQueueSizeMode(mode, forceRefit: true)
        }
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

    func applyJobsQueueSizeMode(
        _ mode: JobsQueueSizeMode,
        forceRefit: Bool,
        retainUserHeightEnteringAll: Bool = false,
        preserveAllMultijobSavedHeight: Bool = false
    ) {
        var mode = mode
        var forceRefit = forceRefit
        var retainUserHeightEnteringAll = retainUserHeightEnteringAll
        var preserveAllMultijobSavedHeight = preserveAllMultijobSavedHeight
        if rightSidebarSplit.jobsIsSoleVisiblePane(appState: self) {
            mode = .all
            forceRefit = true
            retainUserHeightEnteringAll = false
            preserveAllMultijobSavedHeight = false
        }
        if jobsQueueSizeMode == mode, !forceRefit { return }
        let wasStrip = jobsQueueSizeMode == .strip
        if jobsQueueSizeMode != mode {
            if preserveAllMultijobSavedHeight {
                // ⌘\\ restoring ALL height after ONE/STRIP — keep established + dedicated height.
            } else if retainUserHeightEnteringAll, mode == .all {
                setJobsPaneUserAllMultijobHeightLocked(true)
            } else {
                setJobsPaneUserAllMultijobHeightLocked(false)
            }
            // The card-stack measurement belongs to the previous mode (ALL stack vs ONE first
            // card); size from the fallback estimate until the new panel reports.
            measuredJobsCardStackHeight = 0
        }
        jobsQueueSizeMode = mode
        let isStrip = mode == .strip
        if jobsPaneMiniOptionBracketMode, wasStrip != isStrip {
            imageGenUIRevision += 1
            sidebarLayoutRevision += 1
        }
        JobsQueueSizePersistence.save(mode, config: config)
        config.updateSetting("jobs_pane_compact", value: mode == .strip)
        syncJobsPaneGeometry(forceRefit: forceRefit)
    }

    func cycleJobsQueueSizeMode() {
        setJobsPaneUserAllMultijobHeightLocked(false)
        applyJobsQueueSizeMode(jobsQueueSizeMode.next(), forceRefit: true)
    }

    func setJobsPaneUserAllMultijobHeightLocked(_ locked: Bool) {
        jobsPaneUserSplitterSized = locked
        JobsQueueSizePersistence.saveUserAllMultijobHeightLocked(locked, config: config)
    }

    /// Port of Python ``_saved_jobs_pane_size_mode`` + persisted ALL height lock.
    func restoreJobsQueueSizeModeFromConfig() {
        guard BundleCapabilities.imageGenUIEnabled else { return }
        var mode = JobsQueueSizePersistence.load(config: config)
        if mode == .all, config.bool(forKey: "jobs_pane_compact", default: false) {
            mode = .strip
        }
        jobsQueueSizeMode = mode
    }

    func restoreJobsPaneUserAllMultijobHeightLockFromConfig() {
        guard jobsQueueSizeMode == .all else { return }
        guard JobsQueueSizePersistence.loadUserAllMultijobHeightLocked(config: config) else { return }
        jobsPaneUserSplitterSized = true
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
        guard jobsDisplayMode == .pane, extra > 0 else { return }
        if isAdjustingJobsPaneGeometry {
            jobsPaneRefitDeferred = true
            return
        }
        let mode = jobsQueueSizeMode
        let shrinkWrap = shouldShrinkWrapJobsClient()
        let jobCount = visibleJobsQueueRowCount()
        let usesFixedContent = mode == .one || mode == .strip
            || (mode == .all && (shrinkWrap || jobCount <= 1))

        if mode == .all, !shrinkWrap, jobCount > 1 {
            rightSidebarSplit.growJobsPaneForActionBar(extraContentHeight: extra, appState: self)
        } else if usesFixedContent {
            syncJobsPaneGeometry()
        } else {
            rightSidebarSplit.growJobsPaneForActionBar(extraContentHeight: extra, appState: self)
        }
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
        guard shouldScheduleJobsPaneRefitForContentChange(onQueueChange: false) else { return }
        scheduleJobsPaneGeometryRefit()
    }

    func updateMeasuredJobsQueueGeometry(cardStackHeight: CGFloat) {
        guard jobsQueueCardDetailsReadyForSizing() else { return }
        let tolerance = SidebarPaneLayout.paneFitHeightTolerance(needed: cardStackHeight)
        let grew = cardStackHeight > measuredJobsCardStackHeight + tolerance
        guard abs(measuredJobsCardStackHeight - cardStackHeight) > tolerance else { return }
        measuredJobsCardStackHeight = cardStackHeight
        jobsQueuePanelLayoutRevision += 1
        if grew, !jobsPaneUserHeldAllMultijobHeight() {
            jobsPaneGeometryForceRefit = true
        }
        guard shouldScheduleJobsPaneRefitForContentChange(onQueueChange: true) else { return }
        scheduleJobsPaneGeometryRefit()
    }

    /// User dragged the jobs splitter in ALL with multiple rows; hold height until queue size mode changes.
    func jobsPaneUserHeldAllMultijobHeight() -> Bool {
        guard jobsPaneUserSplitterSized else { return false }
        guard jobsQueueSizeMode == .all else { return false }
        guard visibleJobsQueueRowCount() > 1 else { return false }
        return !shouldShrinkWrapJobsClient()
    }

    /// Port of ``JobQueuePanelWidget.should_auto_resize_sidebar_pane``.
    func shouldAutoResizeJobsSidebarPane() -> Bool {
        if jobsPaneUserSplitterSized { return false }
        switch jobsQueueSizeMode {
        case .one, .strip:
            return true
        case .all:
            return shouldShrinkWrapJobsClient() || visibleJobsQueueRowCount() <= 1
        }
    }

    /// Port of ``JobQueuePanelWidget.should_auto_resize_sidebar_on_queue_change``.
    func shouldAutoResizeJobsSidebarOnQueueChange() -> Bool {
        switch jobsQueueSizeMode {
        case .one:
            return true
        case .strip:
            return false
        case .all:
            return shouldShrinkWrapJobsClient() || visibleJobsQueueRowCount() <= 1
        }
    }

    /// Port of panel geometry notify gating (not ``JOBS_PANE_AUTO_RESIZE_ON_JOB_CHANGE``).
    func shouldScheduleJobsPaneRefitForContentChange(onQueueChange: Bool = false) -> Bool {
        guard jobsDisplayMode == .pane else { return false }
        if onQueueChange {
            return shouldScheduleJobsPaneRefitForQueueChange()
        }
        return shouldAutoResizeJobsSidebarPane()
    }

    /// Port of ``JobQueuePanelWidget._notify_sidebar_geometry_if_needed`` queue-change branch.
    func shouldScheduleJobsPaneRefitForQueueChange() -> Bool {
        if jobsPaneUserHeldAllMultijobHeight() { return false }
        if shouldAutoResizeJobsSidebarOnQueueChange() { return true }
        if jobsQueueSizeMode == .all,
           visibleJobsQueueRowCount() > 1,
           !shouldShrinkWrapJobsClient() {
            return true
        }
        return false
    }

    /// Port of ``right_sidebar_combined._enforce_jobs_all_mode_for_sole_pane``.
    func enforceJobsAllModeForSolePane() {
        guard BundleCapabilities.imageGenUIEnabled else { return }
        guard jobsDisplayMode == .pane else { return }
        guard rightSidebarSplit.jobsIsSoleVisiblePane(appState: self) else { return }
        guard config.bool(forKey: "jobs_visible", default: true) else { return }
        if jobsQueueSizeMode != .all {
            applyJobsQueueSizeMode(.all, forceRefit: true)
            return
        }
        config.updateSetting("jobs_pane_compact", value: false)
        rightSidebarSplit.ensureJobsSolePaneFill(appState: self)
    }

    /// Whether ``ensureJobsPaneFitsContent`` should run (includes multijob grow-only refit).
    func shouldInvokeJobsPaneEnsureFitsRefit(forceRefit: Bool) -> Bool {
        if jobsPaneUserHeldAllMultijobHeight() { return false }
        if jobsPaneUserSplitterSized, !forceRefit { return false }
        if rightSidebarSplit.jobsIsSoleVisiblePane(appState: self) { return true }
        if forceRefit { return true }
        if shouldAutoResizeJobsSidebarPane() { return true }
        if jobsQueueSizeMode == .all,
           visibleJobsQueueRowCount() > 1,
           !shouldShrinkWrapJobsClient() {
            return true
        }
        return false
    }

    func beginJobsPaneGeometryAdjustment() {
        isAdjustingJobsPaneGeometry = true
    }

    func endJobsPaneGeometryAdjustment() {
        isAdjustingJobsPaneGeometry = false
        if jobsPaneRefitDeferred {
            jobsPaneRefitDeferred = false
            guard shouldInvokeJobsPaneEnsureFitsRefit(forceRefit: false) else { return }
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

    func imageGenLastDialogSource(for function: String) -> String? {
        imageGenLastDialogSourceByFunction[function]
    }

    func setImageGenLastDialogSource(_ path: String?, for function: String) {
        guard function == "expand" || function == "infill" else { return }
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            imageGenLastDialogSourceByFunction.removeValue(forKey: function)
        } else {
            imageGenLastDialogSourceByFunction[function] = (trimmed as NSString).standardizingPath
        }
    }

    func setImageGenLastEditSourcePaths(_ paths: [String]) {
        imageGenLastEditSourcePaths = ImageGenEditSourcePaths.normalizedPaths(paths)
    }

    /// True when the unified dialog window is on screen (Python ``existing.isVisible()``).
    var imageGenUnifiedDialogIsVisible: Bool {
        if showImageGenUnifiedDialog { return true }
        guard let window = SceneWindowChrome.imageGenUnifiedWindow() else { return false }
        return window.isVisible
    }

    /// ⌥/ — last-used function with saved settings (Python ``start_active_imagegen_generation``).
    func openImageGenDialogWithLastSettings() {
        guard imageGen.isEnabled else {
            status.show(imageGen.unavailableStatusMessage())
            return
        }
        if imageGenUnifiedDialogIsVisible {
            NotificationCenter.default.post(name: .prowserDismissImageGenDialog, object: nil)
            return
        }
        openImageGenDialog(openWithLastSettings: true)
    }

    func openImageGenDialog(
        function: String? = nil,
        replaceJobID: String? = nil,
        initialPrompt: String? = nil,
        autoImportEXIF: Bool = false,
        autoGenerate: Bool = false,
        editSourcePaths: [String] = [],
        openWithLastSettings: Bool = false,
        primeSourceFromActiveImage: Bool = false
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
            editSourcePaths: editSourcePaths,
            openWithLastSettings: openWithLastSettings,
            primeSourceFromActiveImage: primeSourceFromActiveImage
        )
        let wasAlreadyOpen = showImageGenUnifiedDialog
        let requestUnchanged = newRequest == imageGenDialogRequest
        imageGenDialogRequest = newRequest
        if wasAlreadyOpen {
            if requestUnchanged {
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
                autoImportEXIF: true,
                primeSourceFromActiveImage: true
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

    func confirmCancelJob(id: String, skipConfirmation: Bool) {
        if skipConfirmation {
            imageGen.cancelJob(id: id)
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
        if quitConfirmationDialogInFlight {
            return false
        }
        quitConfirmationDialogInFlight = true
        Task { await runQuitConfirmationDialog() }
        return false
    }

    private func runQuitConfirmationDialog() async {
        defer { quitConfirmationDialogInFlight = false }
        imageGen.prepareQuitConfirmationStrip()
        let (stripAccessory, teardownStripLiveUpdates) = ActiveJobStripModalAccessory.make(appState: self)
        defer { teardownStripLiveUpdates() }

        let parentWindow = BrowserWindowIdentity.resolveMainBrowserWindow()
        let choice = await StyledMessageDialog.presentNonModal(
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
            accessoryView: stripAccessory,
            parentWindow: parentWindow,
            shouldAutoDismiss: { [imageGen] in !imageGen.quitInterruptsActiveWorker() },
            onLiveUpdateTick: { [imageGen] in imageGen.refreshQuitConfirmationStripLive() }
        )
        switch choice {
        case 1:
            imageGen.prepareForShutdown()
            performConfirmedApplicationQuit()
        case 2:
            imageGen.setDeferredQuitAppState(self)
            imageGen.beginQuitAfterCurrentWorker()
        default:
            break
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

    func setJobsPaneMiniOptionBracketMode(_ enabled: Bool) {
        guard jobsPaneMiniOptionBracketMode != enabled else { return }
        jobsPaneMiniOptionBracketMode = enabled
        config.updateSetting("jobs_pane_mini_option_bracket_mode", value: enabled)
        config.applySettingsChange(emit: eventBus)
        if enabled {
            applyJobsQueueSizeMode(.strip, forceRefit: true)
        }
        imageGenUIRevision += 1
        sidebarLayoutRevision += 1
        syncJobsPaneGeometry()
    }

    /// After loading `jobs_pane_mini_option_bracket_mode` from disk.
    func applyLoadedJobsPaneMiniOptionBracketMode() {
        guard jobsPaneMiniOptionBracketMode else { return }
        guard BundleCapabilities.imageGenUIEnabled else { return }
        applyJobsQueueSizeMode(.strip, forceRefit: true)
        imageGenUIRevision += 1
        sidebarLayoutRevision += 1
    }

    func setJobsShowHeldJobs(_ show: Bool) {
        guard jobsShowHeldJobs != show else { return }
        jobsShowHeldJobs = show
        config.updateSetting("jobs_show_held_jobs", value: show)
        config.applySettingsChange(emit: eventBus)
        jobsQueuePanelSync?()
        syncJobsPaneGeometry()
    }

    /// Queue rows shown as job cards (optional hide of per-job held rows).
    func filteredQueueSnapshot() -> [QueueRowSnapshot] {
        let rows = imageGen.queueSnapshot()
        guard jobsShowHeldJobs else {
            return rows.filter { $0.isActive || !$0.held }
        }
        return rows
    }

    func jobsQueueRowsForDisplay(mode: JobsQueueSizeMode) -> [QueueRowSnapshot] {
        let rows = filteredQueueSnapshot()
        switch mode {
        case .strip:
            return []
        case .one:
            return Array(rows.prefix(1))
        case .all:
            return rows
        }
    }

    func visibleJobsQueueRowCount() -> Int {
        filteredQueueSnapshot().count
    }

    /// Pane sizing must wait until async ``refreshQueuedJobStatus`` has built row status views.
    func jobsQueueCardDetailsReadyForSizing() -> Bool {
        let rows = jobsQueueRowsForDisplay(mode: jobsQueueSizeMode)
        guard !rows.isEmpty else { return true }
        return rows.allSatisfy { imageGen.isQueueRowStatusDetailReady($0) }
    }

    func isQueueRowStatusDetailReady(_ row: QueueRowSnapshot) -> Bool {
        imageGen.isQueueRowStatusDetailReady(row)
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
