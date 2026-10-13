import Foundation

/// Swift port of `imagegen_plugins/image_gen_controller.py`.
/// UI refresh is driven by ``AppState/imageGenUIRevision`` (not Swift Observation).
@MainActor
final class ImageGenController {
    private let config: AppConfig
    private let modelTasks: MfluxGenerationTasks
    private let foregroundTasks: FluxPromptTasksStub
    private let registry: ImageGenRegistry
    private weak var loraBridge: LoRABridge?

    private(set) var queue: ImageGenQueueFile = ImageGenQueueFile()
    private(set) var activeJobID: String?
    private(set) var isProcessing = false
    private(set) var lastError = ""
    private(set) var progressMessage = ""
    private(set) var taskStatusHTML = ""
    private(set) var progressivePreviewPath: String?
    private(set) var showProgressiveImages = false
    private var progressiveBrowseOpened = false
    private var activeOutputPath: String?
    private(set) var holdJobQueue = false
    private(set) var queueRevision = 0
    private(set) var dialogBuildPauseCount = 0
    private(set) var selectedJobID: String?
    private(set) var activeStripView = ActiveJobStripStatusView()
    private(set) var skipSeriesCopyInFlight = false
    private(set) var cooldownSecondsRemaining = 0

    private var skipSeriesCopyRequested = false
    private var generationStartTime: Date?
    private var stepProgressStartTime: Date?
    private var stepProgressCompletedAt: Date?
    private var frozenElapsedSeconds: Double?
    private var stepSecondsPerStep: Double?
    private var historicalAvgTotalSeconds: Double?
    private var generationTimingKey: GenerationTimingKey?
    private var liveStep = 0
    private var liveStepTotal = 0
    private var liveEstimateSeconds: Double?
    private var statusRefreshTask: Task<Void, Never>?
    private var copiesTotal = 0
    private var copiesDone = 0
    private var copyBatchActive = false
    private var activeDisplayIndex = 0
    private var activeThumbnailPaths: [String] = []
    /// Last card-input thumbnails from ``buildQueueStatusView`` (matches Python ``_active_job_card_thumbnail_paths``).
    private var activeJobCardThumbnailPathsCache: [String] = []
    private var activePluginID = ""
    private var activeFunction = "create"
    private var activeJobNumber: Int?
    private var pendingValues: [String: Any] = [:]
    /// Settings frozen for the in-flight copy so EXIF survives a mid-run Update
    /// (Python ``_copy_cycle_values`` / ``_copy_cycle_plugin``).
    private var copyCycleValues: [String: Any] = [:]
    private var copyCyclePluginID = ""
    /// Klein-edit aspect/screen-size pad temps from ``build_payload`` (Python ``_aspect_pad_temp_paths``).
    private var aspectPadTempPaths: [String] = []
    private var stepRunning: [String: Any]?
    private var stepPendingDoc: [String: Any]?
    private var jobAIStageActive = false
    private var cooldownTask: Task<Void, Never>?
    private var cooldownDisplayTask: Task<Void, Never>?
    private var cooldownBeforeNextJob = false
    /// Last cooldown second shown in the strip (skip redundant 500ms timer polls).
    private var lastCooldownUISecond: Int?
    /// Visibility + row structure last pushed to the jobs pane. Live progress keeps this key.
    private var lastStripPublishKey = ""
    private var stripLiveSinks: [ObjectIdentifier: @MainActor (ActiveJobStripStatusView) -> Void] = [:]
    private var liveStatusTask: Task<Void, Never>?
    private var activeStatusView: QueueJobStatusView?
    private var quitAfterCurrentWorker = false
    private var deferredQuitWaitAllJobs = false
    private var queueAdvanceSuppressed = false
    private var exitQueuePersisted = false
    private var queuePersistSuppressed = false
    private var startupQueueHold = false
    private var startupQueueReleaseToken = 0
    private var copyBatchCancelled = false
    private var pendingCancelJobID = ""
    private var suppressTaskFailureUI = false
    /// Set when the user confirms quit during an active worker so a second ``applicationShouldTerminate`` can finish (Python ``_api_quit_in_progress``).
    private var terminateQuitConfirmed = false
    private let deferredQuitDialog = DeferredQuitDialog()

    var onDeferredQuitComplete: (() -> Void)?

    var isEnabled: Bool {
        guard BundleCapabilities.imageGenUIEnabled else { return false }
        if registry.isAvailable { return true }
        if MfluxToolchain.shared.isAvailable { return true }
        return FileManager.default.isExecutableFile(atPath: config.imagegenVenvPythonPath())
            && ImageGenPythonBundle.rootURL() != nil
    }

    /// Status-bar hint when ``isEnabled`` is false (menu uses the same gate).
    func unavailableStatusMessage() -> String {
        if !BundleCapabilities.imageGenUIEnabled {
            return "Image generation is not included in this build."
        }
        if ImageGenPythonBundle.rootURL() == nil {
            return "Image generation: bundled pipeline scripts are missing from the app."
        }
        if !MfluxToolchain.shared.isAvailable,
           !FileManager.default.isExecutableFile(atPath: config.imagegenVenvPythonPath()) {
            let detail = MfluxToolchain.shared.lastProbeError
            if !detail.isEmpty { return detail }
            return "Image generation: install the imagegen venv in Preferences → Image Generation."
        }
        return "Image generation is not available."
    }

    /// Port of Python ``can_skip_active_series_copy``: an in-flight ``generate`` copy may be
    /// ended early (single-copy jobs too — skipping the last copy finishes the job).
    var canSkipActiveSeriesCopy: Bool {
        if skipSeriesCopyRequested { return false }
        guard modelTasks.isBusy, modelTasks.activeKind == "generate" else { return false }
        return cooldownSecondsRemaining == 0
    }

    func activeJobRelationHeading(for path: String) -> String? {
        guard isEnabled, viewingPathMatchesActiveGeneration(path) else { return nil }
        if viewingPathIsActiveGenerationOutput(path) {
            return "Output of Active Job"
        }
        return "Input to Active Job"
    }

    func viewingPathMatchesActiveGeneration(_ path: String) -> Bool {
        guard isEnabled, !path.isEmpty else { return false }
        guard isProcessing || cooldownSecondsRemaining > 0 else { return false }
        let norm = normalizedImagePath(path)
        return pathsAssociatedWithActiveGeneration().contains(norm)
    }

    func viewingPathIsActiveGenerationOutput(_ path: String) -> Bool {
        guard let activeOutputPath, !activeOutputPath.isEmpty else { return false }
        guard isProcessing || cooldownSecondsRemaining > 0 else { return false }
        return normalizedImagePath(path) == normalizedImagePath(activeOutputPath)
    }

    /// MFLUX stepwise workers still write previews to the job output path; the UI must
    /// ignore those disk updates when intermediate images are off (Python gates browse refresh).
    func shouldSuppressGenerationOutputDiskUpdates(for path: String) -> Bool {
        guard !showProgressiveImages else { return false }
        return viewingPathIsActiveGenerationOutput(path)
    }

    /// Port of Python ``_progressive_images_supported_for_work``.
    func progressiveImagesSupportedForWork() -> Bool {
        if pipelineSupportsProgressiveImages(pluginID: activePluginID) {
            return true
        }
        for job in queue.jobs {
            if pipelineSupportsProgressiveImages(pluginID: job.pluginID) {
                return true
            }
        }
        return false
    }

    private func pipelineSupportsProgressiveImages(pluginID: String) -> Bool {
        guard !pluginID.isEmpty,
              let plugin = ImageGenPluginCatalog.plugin(pluginID: pluginID) else {
            return false
        }
        return ImageGenPipelineModes.mode(pipelineID: plugin.pipelineID)?.supportsProgressiveImages == true
    }

    var isDialogBuildPaused: Bool { dialogBuildPauseCount > 0 }

    var onImageGenerated: ((String) -> Void)?
    /// Called when a progressive step preview is written to disk (debounced by AppState).
    /// Second argument is true when browse should be entered (first preview or final step).
    var onProgressivePreview: ((String, Bool, Int, Int) -> Void)?
    var onQueueChanged: (() -> Void)?

    /// In-place progress-strip updates (fill, elapsed, cooldown count). Does not refresh job cards.
    func setStripLiveSink(
        _ id: ObjectIdentifier,
        _ sink: (@MainActor (ActiveJobStripStatusView) -> Void)?
    ) {
        if let sink {
            stripLiveSinks[id] = sink
        } else {
            stripLiveSinks.removeValue(forKey: id)
        }
    }

    init(
        config: AppConfig,
        modelTasks: MfluxGenerationTasks,
        foregroundTasks: FluxPromptTasksStub,
        registry: ImageGenRegistry
    ) {
        self.config = config
        self.modelTasks = modelTasks
        self.foregroundTasks = foregroundTasks
        self.registry = registry
        let imagegen = config.rawSettings()["imagegen"] as? [String: Any] ?? [:]
        reloadToolbarSettings(from: imagegen)
        restorePersistedJobQueue()
        wireBridgeCallbacks()
    }

    func bind(loraBridge: LoRABridge) {
        self.loraBridge = loraBridge
    }

    private func snapshotSubmitValues(pluginID: String, values: [String: Any]) async throws -> [String: Any] {
        try await loraBridge?.ensureCatalogMigrated()
        return try await registry.normalizeValues(pluginID: pluginID, values: values, mode: "snapshot")
    }

    func beginImageGenDialogBuild() {
        dialogBuildPauseCount += 1
    }

    func endImageGenDialogBuild() {
        dialogBuildPauseCount = max(0, dialogBuildPauseCount - 1)
        if dialogBuildPauseCount == 0 {
            bumpQueueRevision()
        }
    }

    func reloadQueue() {
        restorePersistedJobQueue()
    }

    func reloadEnvironment() {
        MfluxToolchain.shared.bind(config: config)
        bumpQueueRevision()
        onQueueChanged?()
    }

    func scheduleStartupQueueRelease(delayMs: Int = 6_000) {
        guard startupQueueHold, !holdJobQueue else { return }
        startupQueueReleaseToken += 1
        let token = startupQueueReleaseToken
        Task { @MainActor [weak self] in
            guard let self else { return }
            if delayMs > 0 {
                try? await Task.sleep(for: .milliseconds(delayMs))
            }
            guard token == self.startupQueueReleaseToken else { return }
            self.releaseStartupQueueHold()
        }
    }

    func selectJob(id: String?) {
        selectedJobID = id
        bumpQueueRevision()
    }

    func jobsPaneTitleSuffix() -> String {
        guard holdJobQueue else { return "" }
        if activeJobID != nil && (isProcessing || cooldownSecondsRemaining > 0) {
            return " - Quiesce"
        }
        return " - HOLD"
    }

    func reloadToolbarSettings(from imagegen: [String: Any]) {
        showProgressiveImages = ImageGenPipelineModes.showProgressiveImages(in: imagegen)
        let newHold = ImageGenPipelineModes.boolFromSettingsValue(imagegen["hold_job_queue"])
        if newHold {
            startupQueueReleaseToken += 1
            startupQueueHold = false
        }
        holdJobQueue = newHold
    }

    func setShowProgressiveImages(_ enabled: Bool) {
        guard showProgressiveImages != enabled else { return }
        showProgressiveImages = enabled
        mutateImagegen { $0["show_progressive_images"] = enabled }
        if enabled,
           isProcessing,
           let path = activeOutputPath,
           !path.isEmpty {
            progressiveBrowseOpened = false
            onProgressivePreview?(path, true, liveStep, liveStepTotal)
        }
        bumpStripUI()
    }

    func resetProgressiveBrowseOpened() {
        progressiveBrowseOpened = false
    }

    func noteProgressiveBrowseOpened() {
        progressiveBrowseOpened = true
    }

    func setHoldJobQueue(_ enabled: Bool) {
        guard holdJobQueue != enabled else { return }
        holdJobQueue = enabled
        mutateImagegen { $0["hold_job_queue"] = enabled }
        if enabled {
            // A multi-copy job already between copies must leave the running slot now.
            _ = applyQueueHoldAfterCurrentCopy()
            scheduleUnloadImageModelForQueueHold()
        }
        if !enabled {
            startupQueueHold = false
            resumeAfterHoldReleased()
        }
        bumpQueueRevision()
    }

    func skipActiveSeriesCopy() {
        guard canSkipActiveSeriesCopy else { return }
        skipSeriesCopyInFlight = true
        skipSeriesCopyRequested = true
        bumpQueueRevision()
        // Python defers the worker cancel one tick so the toolbar shows "Skipping copy..." first.
        Task { @MainActor [weak self] in
            guard let self, self.skipSeriesCopyRequested else { return }
            self.modelTasks.cancel()
        }
    }

    /// Strip skip arrow (Python ``skip_copy_cooldown``): end the cooldown early and run the
    /// same elapsed handler the timer would (next copy, or next queued job after a job cooldown).
    func skipCopyCooldown() {
        guard cooldownSecondsRemaining > 0 else { return }
        cooldownTask?.cancel()
        cooldownTask = nil
        cooldownDisplayTask?.cancel()
        let afterJob = cooldownBeforeNextJob
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.onCooldownElapsed {
                if afterJob {
                    await self.startNextQueuedJobIfIdle()
                } else {
                    await self.promoteAndRunNextStep()
                }
            }
        }
    }

    // MARK: - Submission

    func enqueueGeneration(
        pluginID: String,
        function: String,
        values: [String: Any],
        copies: Int? = nil
    ) async throws {
        let normalizedCopies = JobStepQueue.normalizeCopies(copies ?? values["copies"] ?? 1)
        var submitValues = values
        submitValues["copies"] = normalizedCopies
        submitValues = try await snapshotSubmitValues(pluginID: pluginID, values: submitValues)
        var steps = try await registry.materializeSteps(pluginID: pluginID, values: submitValues, copies: normalizedCopies)
        let prompt = submitValues["prompt"] as? String ?? ""
        steps = JobStepQueue.ensureStepsHavePrompt(steps, prompt: prompt, jobValues: submitValues)
        var job = ImageGenQueuedJob(
            pluginID: pluginID,
            function: function,
            values: submitValues,
            copiesTotal: normalizedCopies,
            statusHTML: "Queued",
            fullPrompt: prompt,
            steps: steps
        )
        job.jobNumber = ImageGenJobNumber.allocate(config: config)
        job.thumbnailPaths = JobCardThumbnailPaths.paths(pluginID: pluginID, values: submitValues)
        job.referencesInvalid = JobCardThumbnailPaths.referencesInvalid(pluginID: pluginID, values: submitValues)
        queue.jobs.append(job)
        let index = queue.jobs.count - 1
        await refreshQueuedJobStatus(at: index)
        persistQueue()
        bumpQueueRevision()
        if !isProcessing && !holdJobQueue {
            await startNextQueuedJobIfIdle()
        }
    }

    func enqueueCreate(prompt: String, width: Int = 1024, height: Int = 1024) async throws {
        let plugins = try await registry.listPlugins(function: "create")
        guard let plugin = plugins.first(where: { ($0["available"] as? Bool) == true }) ?? plugins.first else {
            throw ImageGenError.unavailable
        }
        let pluginID = plugin["plugin_id"] as? String ?? "flux_schnell_play"
        var values = plugin["merged_defaults"] as? [String: Any] ?? [:]
        values["prompt"] = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        values["width"] = width
        values["height"] = height
        try await enqueueGeneration(pluginID: pluginID, function: "create", values: values, copies: 1)
    }

    // MARK: - Queue management

    func queueSnapshot() -> [QueueRowSnapshot] {
        var pending = queue.jobs
            .filter { $0.jobID != activeJobID }
            .map { job in
                QueueRowSnapshot(
                    jobID: job.jobID,
                    isActive: false,
                    statusHTML: job.statusHTML,
                    statusView: presentationStatusView(for: job),
                    thumbnailPaths: cardThumbnailPaths(job.thumbnailPaths),
                    fullPrompt: job.fullPrompt,
                    referencesInvalid: job.referencesInvalid,
                    pluginUnavailable: job.pluginUnavailable,
                    statusLabel: job.statusLabel,
                    copiesTotal: job.copiesTotal,
                    jobNumber: job.jobNumber,
                    held: job.held,
                    inError: job.inError
                )
            }
        pending = orderSnapshotRowsUnheldBeforeHeld(pending)
        if let activeJobID {
            let activeRow = QueueRowSnapshot(
                jobID: activeJobID,
                isActive: true,
                statusHTML: taskStatusHTML.isEmpty ? progressMessage : taskStatusHTML,
                statusView: activeStatusView,
                thumbnailPaths: activeJobCardThumbnailPaths(),
                fullPrompt: pendingValues["prompt"] as? String ?? "",
                referencesInvalid: false,
                pluginUnavailable: false,
                statusLabel: progressMessage,
                copiesTotal: copiesTotal,
                jobNumber: activeJobNumber,
                held: activeJobHeld(),
                inError: false
            )
            return [activeRow] + pending
        }
        return pending
    }

    private func orderSnapshotRowsUnheldBeforeHeld(_ rows: [QueueRowSnapshot]) -> [QueueRowSnapshot] {
        let unheld = rows.filter { !$0.held }
        let held = rows.filter { $0.held }
        return unheld + held
    }

    private func presentationStatusView(for job: ImageGenQueuedJob) -> QueueJobStatusView? {
        if job.inError {
            return QueueJobStatusView.queueStatusViewWithErrorBanner(
                job.statusView,
                errorMessage: job.errorMessage
            )
        }
        return job.statusView
    }

    func moveJob(before beforeJobID: String?, jobID: String) {
        let rows = queueSnapshot()
        guard let fromIndex = rows.firstIndex(where: { $0.jobID == jobID }) else { return }
        var targetIndex = rows.count
        if let beforeJobID, let beforeIndex = rows.firstIndex(where: { $0.jobID == beforeJobID }) {
            targetIndex = beforeIndex
        }
        if fromIndex == targetIndex { return }

        var ids = rows.map(\.jobID)
        ids.remove(at: fromIndex)
        let insertAt = targetIndex > fromIndex ? targetIndex - 1 : targetIndex
        ids.insert(jobID, at: max(0, min(insertAt, ids.count)))

        var newQueue: [ImageGenQueuedJob] = []
        var newActiveIndex = 0
        for (idx, jid) in ids.enumerated() {
            if jid == activeJobID { newActiveIndex = idx }
            if let job = queue.jobs.first(where: { $0.jobID == jid }) {
                newQueue.append(job)
            } else if jid == activeJobID, let activeJob = buildActiveQueuedJob() {
                newQueue.append(activeJob)
            }
        }
        queue.jobs = newQueue.filter { $0.jobID != activeJobID }
        activeDisplayIndex = newActiveIndex
        queue.activeDisplayIndex = activeDisplayIndex
        persistQueue()
        bumpQueueRevision()
    }

    func replaceQueuedJob(jobID: String, pluginID: String, function: String, values: [String: Any]) async throws {
        guard let index = queue.jobs.firstIndex(where: { $0.jobID == jobID }) else { return }
        let copies = JobStepQueue.normalizeCopies(values["copies"] ?? 1)
        var submitValues = values
        submitValues["copies"] = copies
        submitValues = try await snapshotSubmitValues(pluginID: pluginID, values: submitValues)
        var steps = try await registry.materializeSteps(pluginID: pluginID, values: submitValues, copies: copies)
        JobStepQueue.stampSeriesCopiesOnSteps(&steps, copies: copies)
        queue.jobs[index].pluginID = pluginID
        queue.jobs[index].function = function
        queue.jobs[index].values = submitValues
        queue.jobs[index].copiesTotal = copies
        queue.jobs[index].steps = steps
        queue.jobs[index].fullPrompt = submitValues["prompt"] as? String ?? ""
        queue.jobs[index].statusHTML = "Queued"
        queue.jobs[index].pluginUnavailable = false
        queue.jobs[index].inError = false
        queue.jobs[index].errorMessage = ""
        queue.jobs[index].thumbnailPaths = JobCardThumbnailPaths.paths(
            pluginID: pluginID,
            values: submitValues
        )
        queue.jobs[index].referencesInvalid = JobCardThumbnailPaths.referencesInvalid(
            pluginID: pluginID,
            values: submitValues
        )
        await refreshQueuedJobStatus(at: index)
        clearQueueErrorDisplay()
        if activeJobID == jobID {
            resetActiveGenerationStateForQueueRetry()
        }
        persistQueue()
        bumpQueueRevision()
        if !isProcessing, !holdJobQueue, !startupQueueHold, !queueAdvanceSuppressed {
            processNextIfIdle()
        }
    }

    /// Clear jobs-pane error text after Replace/Update (stale ``lastError`` is not a start gate).
    private func clearQueueErrorDisplay() {
        lastError = ""
        if !isProcessing, activeJobID == nil {
            progressMessage = ""
            taskStatusHTML = ""
        }
    }

    /// Drop in-flight controller state for a queue row that failed to start (Python ``_clear_active_job_head_without_demote``).
    private func resetActiveGenerationStateForQueueRetry() {
        stopLiveStatusTimer()
        removeAspectPadTemps()
        clearCopyCycleExifSnapshot()
        activeJobID = nil
        activeJobNumber = nil
        isProcessing = false
        progressMessage = ""
        taskStatusHTML = ""
        activeStatusView = nil
        activeStripView = ActiveJobStripStatusView()
        resetActiveJobProgressTracking()
        generationStartTime = nil
        skipSeriesCopyInFlight = false
        progressivePreviewPath = nil
        activeOutputPath = nil
        progressiveBrowseOpened = false
        activeThumbnailPaths = []
        activeJobCardThumbnailPathsCache = []
        stepRunning = nil
        stepPendingDoc = nil
        copyBatchActive = false
        copiesTotal = 0
        copiesDone = 0
        jobAIStageActive = false
        activePluginID = ""
        activeFunction = "create"
        pendingValues = [:]
        copyBatchCancelled = false
        pendingCancelJobID = ""
    }

    /// Status-bar task dot (Python ``_update_status_bar_indicator``).
    func statusBarIndicatorKind() -> String? {
        guard isEnabled else { return nil }
        if modelTasks.workerNeedsCleanup {
            return "cleanup"
        }
        if cooldownSecondsRemaining > 0 {
            return "cooldown"
        }
        if foregroundTasks.isBusy {
            return "caption"
        }
        if modelTasks.isBusy || jobAIStageActive || isProcessing {
            return "generate"
        }
        return nil
    }

    func updateActiveJobRemaining(jobID: String, pluginID: String, values: [String: Any]) async throws {
        guard jobID == activeJobID else { return }
        let inProgress = isProcessing ? 1 : 0
        var remaining = JobStepQueue.normalizeCopies(values["copies"] ?? 1)
        if inProgress > 0 { remaining = max(1, remaining) }
        let copies = copiesDone + remaining
        var submitValues = values
        submitValues["copies"] = copies
        submitValues = try await snapshotSubmitValues(pluginID: pluginID, values: submitValues)
        copiesTotal = copies
        if JobStepQueue.isSeriesContinuousCopies(copiesTotal) {
            copyBatchActive = true
        } else {
            copyBatchActive = copies > 1 || copiesDone > 0
        }
        activePluginID = pluginID
        pendingValues = submitValues
        let future = max(0, copies - copiesDone - inProgress)
        if var doc = stepPendingDoc {
            let steps = try JobStepQueue.materializePendingStepsFromUpdate(
                pluginID: pluginID,
                templateValues: submitValues,
                count: future
            )
            doc["steps"] = steps
            stepPendingDoc = doc
        }
        await syncActiveJobQueueRow(pluginID: pluginID, values: submitValues, copiesTotal: copies)
        await refreshActiveJobStatusView()
        persistStepState()
        persistQueue()
        bumpQueueRevision()
    }

    /// Pending queue row or the active job (Python ``job_record_for_row``).
    func jobForQueueEditor(jobID: String) -> ImageGenQueuedJob? {
        if jobID == activeJobID {
            return buildActiveQueuedJob()
        }
        return queue.jobs.first(where: { $0.jobID == jobID })
    }

    func copiesForJobEditor(jobID: String) -> Int? {
        if jobID == activeJobID {
            if JobStepQueue.isSeriesContinuousCopies(copiesTotal) {
                return JobStepQueue.seriesContinuousCopies
            }
            return max(1, copiesTotal - copiesDone)
        }
        guard let job = queue.jobs.first(where: { $0.jobID == jobID }) else { return nil }
        if JobStepQueue.isSeriesContinuousCopies(job.copiesTotal) {
            return JobStepQueue.seriesContinuousCopies
        }
        return max(1, job.copiesTotal)
    }

    func isQueuedJobReplaceable(jobID: String) -> Bool {
        jobID != activeJobID && queue.jobs.contains(where: { $0.jobID == jobID })
    }

    func isActiveJobRemainingUpdatable(jobID: String) -> Bool {
        jobID == activeJobID && (JobStepQueue.pendingStepCount(stepPendingDoc) > 0 || copyBatchActive)
    }

    func cancelJob(id: String, cascade: Bool = false) {
        if id == activeJobID {
            cancelActiveJob()
            return
        }
        if cascade {
            guard let row = queueSnapshot().firstIndex(where: { $0.jobID == id }) else { return }
            let suffix = queueSnapshot().suffix(from: row).map(\.jobID)
            for jobID in suffix where jobID != activeJobID {
                queue.jobs.removeAll { $0.jobID == jobID }
            }
            if let selectedJobID, suffix.contains(selectedJobID) {
                self.selectedJobID = nil
            }
            persistQueue()
            bumpQueueRevision()
            return
        }
        queue.jobs.removeAll { $0.jobID == id }
        if selectedJobID == id {
            selectedJobID = nil
        }
        persistQueue()
        bumpQueueRevision()
    }

    func cancelActiveJob() {
        guard isRunning() || activeJobID != nil else { return }
        copyBatchCancelled = true
        skipSeriesCopyRequested = false
        pendingCancelJobID = activeJobID ?? ""
        cooldownTask?.cancel()
        cooldownDisplayTask?.cancel()
        cooldownSecondsRemaining = 0
        if jobAIStageActive {
            foregroundTasks.cancel()
            jobAIStageActive = false
        }
        modelTasks.cancel()
        finishCancelledBatchIfNeeded()
    }

    func removeJob(id: String) {
        cancelJob(id: id)
    }

    // MARK: - Series controls

    func rowIndex(forJobID jobID: String) -> Int? {
        let rows = queueSnapshot()
        return rows.firstIndex(where: { $0.jobID == jobID })
    }

    /// Python ``add_series_cycle_for_row`` / action bar + (targets selected row, not only active).
    func addSeriesCycle(forJobID jobID: String, delta: Int = 1) {
        Task { @MainActor in
            await addSeriesCycleAsync(jobID: jobID, delta: delta)
        }
    }

    func setSeriesContinuous(forJobID jobID: String) {
        Task { @MainActor in
            await setSeriesContinuousAsync(jobID: jobID)
        }
    }

    func subtractSeriesRemaining(forJobID jobID: String, removeAll: Bool = false) {
        Task { @MainActor in
            if removeAll {
                await clearSeriesRemainingAsync(jobID: jobID)
            } else if jobID == activeJobID {
                subtractActiveSeriesRemaining()
            } else {
                await adjustQueuedSeriesTotalAsync(jobID: jobID, delta: -1)
            }
        }
    }

    private func addSeriesCycleAsync(jobID: String, delta: Int) async {
        guard delta != 0 else { return }
        if jobID == activeJobID {
            if delta > 0 {
                addActiveSeriesCycle(delta: delta)
            } else {
                subtractActiveSeriesRemaining()
            }
            return
        }
        await adjustQueuedSeriesTotalAsync(jobID: jobID, delta: delta)
    }

    private func setSeriesContinuousAsync(jobID: String) async {
        if jobID == activeJobID {
            setActiveSeriesContinuous()
            return
        }
        guard let index = queue.jobs.firstIndex(where: { $0.jobID == jobID }) else { return }
        var job = queue.jobs[index]
        if job.pluginUnavailable || JobStepQueue.isSeriesContinuousCopies(job.copiesTotal) { return }
        do {
            var values = job.values
            values["copies"] = JobStepQueue.seriesContinuousCopies
            if job.steps.isEmpty {
                job.steps = try await registry.materializeSteps(
                    pluginID: job.pluginID,
                    values: values,
                    copies: JobStepQueue.seriesContinuousCopies
                )
            }
            job.values = values
            job.copiesTotal = JobStepQueue.seriesContinuousCopies
            queue.jobs[index] = job
            await refreshQueuedJobStatus(at: index)
            persistQueue()
            bumpQueueRevision()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func clearSeriesRemainingAsync(jobID: String) async {
        if jobID == activeJobID {
            if clearActiveSeriesRemaining() {
                bumpQueueRevision()
            }
            return
        }
        guard let index = queue.jobs.firstIndex(where: { $0.jobID == jobID }) else { return }
        var job = queue.jobs[index]
        if !job.steps.isEmpty {
            job.steps = [job.steps[0]]
        }
        job.copiesTotal = 1
        job.values["copies"] = 1
        JobStepQueue.stampSeriesCopiesOnSteps(&job.steps, copies: 1)
        queue.jobs[index] = job
        await refreshQueuedJobStatus(at: index)
        persistQueue()
        bumpQueueRevision()
    }

    private func adjustQueuedSeriesTotalAsync(jobID: String, delta: Int) async {
        guard delta != 0,
              let index = queue.jobs.firstIndex(where: { $0.jobID == jobID }) else { return }
        var job = queue.jobs[index]
        if job.pluginUnavailable { return }
        do {
            if job.steps.isEmpty {
                job.steps = try await registry.materializeSteps(
                    pluginID: job.pluginID,
                    values: job.values,
                    copies: max(1, job.copiesTotal)
                )
            }
            if delta > 0 {
                if job.steps.count >= JobStepQueue.seriesContinuousCopies { return }
                let newTotal = min(JobStepQueue.seriesContinuousCopies, job.steps.count + delta)
                guard newTotal > job.steps.count else { return }
                let template = JobStepQueue.mergeStepIntoValues(job.steps[0])
                let extra = try JobStepQueue.materializePendingStepsFromUpdate(
                    pluginID: job.pluginID,
                    templateValues: template,
                    count: newTotal - job.steps.count
                )
                job.steps.append(contentsOf: extra)
            } else {
                if JobStepQueue.isSeriesContinuousCopies(job.copiesTotal) {
                    let newTotal = JobStepQueue.seriesContinuousCopies - 1
                    let template = JobStepQueue.mergeStepIntoValues(job.steps[0])
                    var values = template
                    values["copies"] = newTotal
                    job.steps = try await registry.materializeSteps(
                        pluginID: job.pluginID,
                        values: values,
                        copies: newTotal
                    )
                } else {
                    let remaining = max(0, job.steps.count - 1)
                    guard remaining > 0 else { return }
                    let newTotal = max(1, job.steps.count + delta)
                    guard newTotal != job.steps.count else { return }
                    job.steps = job.steps.prefix(newTotal).map { $0 }
                }
            }
            job.copiesTotal = job.steps.count
            job.values["copies"] = job.copiesTotal
            JobStepQueue.stampSeriesCopiesOnSteps(&job.steps, copies: job.copiesTotal)
            queue.jobs[index] = job
            await refreshQueuedJobStatus(at: index)
            persistQueue()
            bumpQueueRevision()
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    private func clearActiveSeriesRemaining() -> Bool {
        guard activeSeriesRemainingAfter() > 0 else { return false }
        subtractActiveSeriesRemaining(removeAll: true)
        return true
    }

    func addActiveSeriesCycle(delta: Int = 1) {
        guard activeJobID != nil else { return }
        if JobStepQueue.isSeriesContinuousCopies(copiesTotal) { return }
        let proposed = copiesTotal + delta
        if JobStepQueue.isSeriesContinuousCopies(proposed) {
            setActiveSeriesContinuous()
            return
        }
        copiesTotal = min(JobStepQueue.seriesContinuousCopies - 1, proposed)
        copyBatchActive = copiesTotal > 1
        appendPendingSteps(count: delta)
        persistStepState()
        Task { await refreshActiveJobStatusView() }
        bumpQueueRevision()
    }

    func subtractActiveSeriesRemaining(delta: Int = 1, removeAll: Bool = false) {
        guard activeJobID != nil else { return }
        if removeAll {
            clearPendingSteps()
            copiesTotal = copiesDone + (isProcessing ? 1 : 0)
        } else {
            let pending = JobStepQueue.pendingStepCount(stepPendingDoc)
            let remove = min(delta, pending)
            trimPendingSteps(count: remove)
            copiesTotal = max(copiesDone + (isProcessing ? 1 : 0), copiesTotal - remove)
        }
        copyBatchActive = copiesTotal > 1
        persistStepState()
        Task { await refreshActiveJobStatusView() }
        bumpQueueRevision()
    }

    func setActiveSeriesContinuous() {
        guard activeJobID != nil else { return }
        copiesTotal = JobStepQueue.seriesContinuousCopies
        copyBatchActive = true
        pendingValues["copies"] = JobStepQueue.seriesContinuousCopies
        if var doc = stepPendingDoc {
            activateContinuousSeriesPendingDoc(&doc)
            stepPendingDoc = doc
        }
        persistStepState()
        bumpQueueRevision()
    }

    func setActiveSeriesRefinement(image: Bool, text: Bool) {
        pendingValues["series_refinement"] = image
        pendingValues["series_prompt_refinement"] = text
        if var step = stepRunning {
            var values = JobStepQueue.stepValues(step)
            values["series_refinement"] = image
            values["series_prompt_refinement"] = text
            step["values"] = values
            stepRunning = step
        }
        persistStepState()
        Task { await refreshActiveJobStatusView() }
        bumpQueueRevision()
    }

    func setSeriesRefinement(for jobID: String, image: Bool? = nil, text: Bool? = nil) {
        if jobID == activeJobID {
            let img = image ?? (pendingValues["series_refinement"] as? Bool ?? false)
            let txt = text ?? (pendingValues["series_prompt_refinement"] as? Bool ?? false)
            setActiveSeriesRefinement(image: img, text: txt)
            return
        }
        guard let index = queue.jobs.firstIndex(where: { $0.jobID == jobID }) else { return }
        if let image {
            queue.jobs[index].values["series_refinement"] = image
        }
        if let text {
            queue.jobs[index].values["series_prompt_refinement"] = text
        }
        Task {
            await refreshQueuedJobStatus(at: index)
            persistQueue()
            bumpQueueRevision()
        }
    }

    func actionBarState(for jobID: String) -> JobQueueActionBarState {
        guard let row = queueSnapshot().first(where: { $0.jobID == jobID }) else {
            return .empty
        }
        let remaining = seriesRemainingAfter(for: jobID)
        var state = JobQueueActionBarState()
        state.hasRow = true
        state.canAddSeries = canAddSeriesCycle(for: jobID)
        state.canSubtractSeries = canSubtractSeriesCycle(for: jobID)
        state.imageRefinementVisible = remaining > 0 && row.copiesTotal > 1 && jobSupportsImageSeriesRefinement(jobID: jobID)
        state.textRefinementVisible = remaining > 0 && row.copiesTotal > 1 && jobSupportsTextSeriesRefinement(jobID: jobID)
        state.imageRefinementChecked = seriesRefinementEnabled(for: jobID)
        state.textRefinementChecked = seriesPromptRefinementEnabled(for: jobID)
        return state
    }

    private func seriesRemainingAfter(for jobID: String) -> Int {
        if jobID == activeJobID {
            return activeSeriesRemainingAfter()
        }
        guard let job = queue.jobs.first(where: { $0.jobID == jobID }) else { return 0 }
        if !job.steps.isEmpty {
            return max(0, job.steps.count - 1)
        }
        return max(0, job.copiesTotal - 1)
    }

    private func canAddSeriesCycle(for jobID: String) -> Bool {
        if jobID == activeJobID {
            guard activeJobID != nil else { return false }
            guard !JobStepQueue.isSeriesContinuousCopies(copiesTotal) else { return false }
            return copiesTotal < JobStepQueue.seriesContinuousCopies
        }
        guard let job = queue.jobs.first(where: { $0.jobID == jobID }) else { return false }
        if job.pluginUnavailable { return false }
        return !JobStepQueue.isSeriesContinuousCopies(job.copiesTotal)
    }

    private func canSubtractSeriesCycle(for jobID: String) -> Bool {
        if jobID == activeJobID {
            return canSubtractActiveSeriesCycle()
        }
        guard let job = queue.jobs.first(where: { $0.jobID == jobID }) else { return false }
        if JobStepQueue.isSeriesContinuousCopies(job.copiesTotal) { return true }
        return seriesRemainingAfter(for: jobID) > 0
    }

    private func canSubtractActiveSeriesCycle() -> Bool {
        activeSeriesRemainingAfter() > 0
    }

    private func activeSeriesRemainingAfter() -> Int {
        let inProgress = isProcessing ? 1 : 0
        return max(0, copiesTotal - copiesDone - inProgress)
    }

    private func seriesRefinementEnabled(for jobID: String) -> Bool {
        if jobID == activeJobID {
            return pendingValues["series_refinement"] as? Bool ?? false
        }
        return queue.jobs.first(where: { $0.jobID == jobID })?.values["series_refinement"] as? Bool ?? false
    }

    private func seriesPromptRefinementEnabled(for jobID: String) -> Bool {
        if jobID == activeJobID {
            return pendingValues["series_prompt_refinement"] as? Bool ?? false
        }
        return queue.jobs.first(where: { $0.jobID == jobID })?.values["series_prompt_refinement"] as? Bool ?? false
    }

    private func jobSupportsImageSeriesRefinement(jobID: String) -> Bool {
        let function: String
        if jobID == activeJobID {
            function = activeFunction
        } else if let job = queue.jobs.first(where: { $0.jobID == jobID }) {
            function = job.function
        } else {
            return false
        }
        switch function {
        case "create", "edit":
            return true
        default:
            return false
        }
    }

    private func jobSupportsTextSeriesRefinement(jobID: String) -> Bool {
        guard jobSupportsImageSeriesRefinement(jobID: jobID) else { return false }
        let function: String
        if jobID == activeJobID {
            function = activeFunction
        } else if let job = queue.jobs.first(where: { $0.jobID == jobID }) {
            function = job.function
        } else {
            return false
        }
        guard function == "create" || function == "edit" || function == "expand" else { return false }
        return foregroundTasks.isAvailable
    }

    func jobsHeaderStatusText() -> String {
        let rows = queueSnapshot()
        if holdJobQueue {
            if rows.isEmpty { return "" }
            return "=\(rows.count) "
        }
        let waiting = rows.filter { !$0.isActive }.count
        if waiting <= 0 { return "" }
        return "+\(waiting) "
    }

    func jobHeld(jobID: String) -> Bool {
        let id = jobID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return false }
        if id == activeJobID { return activeJobHeld() }
        return queue.jobs.first(where: { $0.jobID == id })?.held ?? false
    }

    func jobInError(jobID: String) -> Bool {
        let id = jobID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return false }
        return queue.jobs.first(where: { $0.jobID == id })?.inError ?? false
    }

    func canClickJobNumber(jobID: String) -> Bool {
        if jobInError(jobID: jobID) { return true }
        return canToggleJobHeld(jobID: jobID)
    }

    func canToggleJobHeld(jobID: String) -> Bool {
        let id = jobID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return false }
        if id != activeJobID {
            return queue.jobs.contains(where: { $0.jobID == id })
        }
        guard activeJobID != nil else { return false }
        if jobAIStageActive || modelTasks.isBusy || cooldownSecondsRemaining > 0 {
            return true
        }
        if isProcessing || copyBatchActive {
            return true
        }
        return true
    }

    @discardableResult
    func releaseJobFromError(jobID: String) -> Bool {
        let id = jobID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, let index = queue.jobs.firstIndex(where: { $0.jobID == id }) else { return false }
        guard queue.jobs[index].inError else { return false }
        queue.jobs[index].inError = false
        queue.jobs[index].errorMessage = ""
        queue.jobs[index].statusHTML = "Queued"
        bumpQueueRevision()
        Task {
            await refreshQueuedJobStatus(at: index)
            persistQueue()
            bumpQueueRevision()
            if activeJobID == nil, !holdJobQueue, !startupQueueHold, !queueAdvanceSuppressed {
                await startNextQueuedJobIfIdle()
            }
        }
        return true
    }

    @discardableResult
    func toggleJobHeld(jobID: String) -> Bool {
        let id = jobID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, canToggleJobHeld(jobID: id) else { return false }
        let newHeld = !jobHeld(jobID: id)
        if id == activeJobID {
            setActiveJobHeld(newHeld)
        } else if let index = queue.jobs.firstIndex(where: { $0.jobID == id }) {
            queue.jobs[index].held = newHeld
        } else {
            return false
        }
        persistQueue()
        bumpQueueRevision()
        if newHeld, id == activeJobID {
            if !generationWorkerActive() {
                _ = yieldActiveBatchIfNotNextToRun()
            }
        } else if !newHeld, activeJobID == nil, !holdJobQueue, !startupQueueHold, !queueAdvanceSuppressed {
            Task { await startNextQueuedJobIfIdle() }
        }
        return true
    }

    private func activeJobHeld() -> Bool {
        JobStepQueue.parseHeldFromDoc(stepPendingDoc)
    }

    /// Port of ``ImageGenController._generation_worker_active``.
    private func generationWorkerActive() -> Bool {
        if jobAIStageActive { return true }
        if modelTasks.isBusy || foregroundTasks.isBusy { return true }
        if modelTasks.workerNeedsCleanup { return true }
        if cooldownSecondsRemaining > 0 { return true }
        return false
    }

    private func jobIDNextInLine() -> String? {
        for row in queueSnapshot() {
            if row.held || row.inError { continue }
            return row.jobID
        }
        return nil
    }

    private func activeIsNextToRun() -> Bool {
        guard let activeJobID, !activeJobID.isEmpty else { return false }
        if activeJobHeld() { return false }
        return jobIDNextInLine() == activeJobID
    }

    /// Port of ``ImageGenController._yield_active_batch_if_not_next_to_run``.
    @discardableResult
    private func yieldActiveBatchIfNotNextToRun() -> Bool {
        if activeIsNextToRun() { return false }
        if copyBatchCancelled {
            finishCopyBatch(cancelled: true)
            return true
        }
        if demoteActiveRemainingToQueue() {
            return true
        }
        if activeJobHeld(), requeueHeldActiveJobAtHead() {
            return true
        }
        if pendingBatchCopies() <= 0 {
            finishActiveJob(cancelled: false)
            return true
        }
        resetActiveGenerationStateForQueueRetry()
        if !queuePersistSuppressed {
            JobStepPersistence.saveActiveRunning(nil, config: config)
            JobStepPersistence.saveActivePending(nil, config: config)
            persistQueue()
        }
        bumpQueueRevision()
        Task { await startNextQueuedJobIfIdle() }
        return true
    }

    /// Port of ``ImageGenController._requeue_held_active_job_at_head``.
    @discardableResult
    private func requeueHeldActiveJobAtHead() -> Bool {
        let jobID = activeJobID ?? ""
        guard !jobID.isEmpty, !activePluginID.isEmpty, activeJobHeld() else { return false }

        let steps: [[String: Any]]
        let submitValues: [String: Any]
        let copies: Int
        if let collected = collectActiveRemainingStepsForRequeue() {
            steps = collected.steps
            submitValues = collected.values
            copies = collected.copies
        } else {
            var values = pendingValues
            let copiesNorm = JobStepQueue.normalizeCopies(values["copies"] ?? copiesTotal)
            values["copies"] = copiesNorm
            guard let materialized = try? JobStepQueue.materializeSteps(
                pluginID: activePluginID,
                templateValues: values,
                copiesTotal: copiesNorm
            ), !materialized.isEmpty else {
                return false
            }
            steps = materialized
            submitValues = values
            copies = copiesNorm
        }

        let fullPrompt = JobStepQueue.resolvedFullPrompt(
            stored: (stepPendingDoc?["display"] as? [String: Any])?["full_prompt"] as? String ?? "",
            values: submitValues,
            steps: steps,
            statusView: activeStatusView
        )
        let thumbs = activeThumbnailPaths.isEmpty
            ? (queue.jobs.first(where: { $0.jobID == jobID })?.thumbnailPaths ?? [])
            : activeThumbnailPaths
        let insertAt = max(0, min(activeDisplayIndex, queue.jobs.count))

        if let index = queue.jobs.firstIndex(where: { $0.jobID == jobID }) {
            queue.jobs[index].pluginID = activePluginID
            queue.jobs[index].function = activeFunction
            queue.jobs[index].pluginUnavailable = false
            queue.jobs[index].values = submitValues
            queue.jobs[index].copiesTotal = copies
            queue.jobs[index].steps = steps
            queue.jobs[index].fullPrompt = fullPrompt
            queue.jobs[index].thumbnailPaths = thumbs
            queue.jobs[index].held = true
            queue.jobs[index].inError = false
            queue.jobs[index].errorMessage = ""
            queue.jobs[index].statusHTML = "Queued"
            if let activeJobNumber {
                queue.jobs[index].jobNumber = activeJobNumber
            }
            Task {
                await refreshQueuedJobStatus(at: index)
                finalizeRequeuedActiveJob()
            }
            return true
        }

        let job = ImageGenQueuedJob(
            jobID: jobID,
            pluginID: activePluginID,
            function: activeFunction,
            values: submitValues,
            copiesTotal: copies,
            statusHTML: "Queued",
            fullPrompt: fullPrompt,
            thumbnailPaths: thumbs,
            steps: steps,
            jobNumber: activeJobNumber,
            held: true
        )
        queue.jobs.insert(job, at: insertAt)
        Task {
            await refreshQueuedJobStatus(at: insertAt)
            finalizeRequeuedActiveJob()
        }
        return true
    }

    private func setActiveJobHeld(_ held: Bool) {
        guard let doc = stepPendingDoc else { return }
        stepPendingDoc = JobStepQueue.applyHeldToDoc(doc, held: held)
        if !queuePersistSuppressed {
            JobStepPersistence.saveActivePending(stepPendingDoc, config: config)
        }
    }

    // MARK: - Internal processing

    private func startNextQueuedJobIfIdle() async {
        if !isEnabled { return }
        if modelTasks.isBusy { return }
        if activeJobID != nil { return }
        if holdJobQueue { return }
        if startupQueueHold { return }
        if queueAdvanceSuppressed { return }
        if modelTasks.workerNeedsCleanup {
            Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                await startNextQueuedJobIfIdle()
            }
            return
        }
        if let head = queue.jobs.first, head.pluginUnavailable, isRunnableQueuedJob(head) {
            lastError =
                "The first queued job uses an unavailable model (\(head.pluginID)). "
                + "Edit or remove it to continue."
            return
        }
        if let head = queue.jobs.first, head.referencesInvalid, isRunnableQueuedJob(head) {
            lastError =
                "The first queued job has missing reference files. "
                + "Edit or remove it to continue."
            return
        }
        guard let index = queue.jobs.firstIndex(where: { isRunnableQueuedJob($0) }) else {
            return
        }
        clearQueueErrorDisplay()
        var job = queue.jobs[index]
        if job.jobNumber == nil {
            job.jobNumber = ImageGenJobNumber.allocate(config: config)
            queue.jobs[index].jobNumber = job.jobNumber
        }
        activeJobNumber = job.jobNumber
        let resolvedPrompt = JobStepQueue.resolvedFullPrompt(
            stored: job.fullPrompt,
            values: job.values,
            steps: job.steps,
            statusView: job.statusView
        )
        if !resolvedPrompt.isEmpty {
            job.fullPrompt = resolvedPrompt
            if (job.values["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                job.values["prompt"] = resolvedPrompt
            }
            job.steps = JobStepQueue.ensureStepsHavePrompt(
                job.steps,
                prompt: resolvedPrompt,
                jobValues: job.values
            )
        }
        var steps = job.steps
        if steps.isEmpty, isEnabled {
            do {
                steps = try await registry.materializeSteps(
                    pluginID: job.pluginID,
                    values: job.values,
                    copies: job.copiesTotal
                )
                steps = JobStepQueue.ensureStepsHavePrompt(
                    steps,
                    prompt: resolvedPrompt,
                    jobValues: job.values
                )
            } catch {
                lastError = error.localizedDescription
                markQueuedJobFailed(at: index, message: error.localizedDescription)
                abortQueuedJobStart()
                return
            }
        }
        guard !steps.isEmpty else {
            markQueuedJobFailed(at: index, message: "No generation steps")
            abortQueuedJobStart()
            return
        }
        activeJobID = job.jobID
        activePluginID = job.pluginID
        activeFunction = job.function
        pendingValues = job.values
        copiesTotal = job.copiesTotal
        copiesDone = 0
        copyBatchActive = job.copiesTotal > 1
        let cardPaths = cardThumbnailPaths(job.thumbnailPaths)
        activeThumbnailPaths = cardPaths
        activeJobCardThumbnailPathsCache = cardPaths
        activeStatusView = job.statusView
        activeDisplayIndex = index
        let continuous = JobStepQueue.isSeriesContinuousCopies(job.copiesTotal)
        let continuousTemplate = continuous && !steps.isEmpty ? steps[0] : nil
        stepPendingDoc = JobStepQueue.buildPendingJobDoc(
            jobID: job.jobID,
            pluginID: job.pluginID,
            function: job.function,
            steps: steps,
            fullPrompt: resolvedPrompt,
            thumbnailPaths: job.thumbnailPaths,
            continuousMode: continuous,
            continuousTemplate: continuousTemplate,
            held: job.held
        )
        // Publish only after status, thumbs, and prompt are installed. An earlier bump
        // painted this job id with the previous active card.
        bumpQueueRevision()
        persistQueue()
        await promoteAndRunNextStep()
    }

    private func promoteAndRunNextStep() async {
        if holdJobQueue {
            _ = demoteActiveRemainingToQueue()
            return
        }
        if yieldActiveBatchIfNotNextToRun() {
            return
        }
        guard var doc = stepPendingDoc else {
            finishOrAbortQueuedJobStart()
            return
        }
        appendContinuousPendingStepIfNeeded(&doc)
        guard let step = JobStepQueue.popNextStep(from: &doc) else {
            stepPendingDoc = doc
            finishOrAbortQueuedJobStart()
            return
        }
        stepPendingDoc = doc
        stepRunning = step
        syncCopiesDoneDisplay()
        isProcessing = true
        generationStartTime = Date()
        liveStep = 0
        liveStepTotal = 0
        liveEstimateSeconds = nil
        progressMessage = "Starting…"
        taskStatusHTML = progressMessage
        startLiveStatusTimer()
        await refreshActiveJobStatusView()
        rebuildActiveStripViewLocally()
        bumpStripUI()

        let displayPrompt = (stepPendingDoc?["display"] as? [String: Any])?["full_prompt"] as? String ?? ""
        let statusViewPrompt = JobStepQueue.promptFromStatusView(activeStatusView)
        let values = JobStepQueue.generationValues(
            from: step,
            jobValues: pendingValues,
            displayFullPrompt: displayPrompt,
            statusViewPrompt: statusViewPrompt
        )
        pendingValues = values
        if JobStepQueue.stepNeedsAI(step) {
            if foregroundTasks.isAvailable {
                await runJobAIStage(values: values)
            } else {
                progressMessage = "AI prompt step skipped (not available)"
                taskStatusHTML = progressMessage
                bumpQueueRevision()
                await launchGeneration(values: values)
            }
            return
        }
        await launchGeneration(values: values)
    }

    private func runJobAIStage(values: [String: Any]) async {
        jobAIStageActive = true
        progressMessage = "Refining prompt…"
        taskStatusHTML = progressMessage
        bumpQueueRevision()
        do {
            let prompt = values["prompt"] as? String ?? ""
            let refined = try await startFluxPrompt(prompt: prompt, values: values)
            var updated = values
            updated["prompt"] = refined
            pendingValues = updated
            if var step = stepRunning {
                var stepValues = JobStepQueue.stepValues(step)
                stepValues["prompt"] = refined
                step["values"] = stepValues
                stepRunning = step
            }
            jobAIStageActive = false
            await launchGeneration(values: updated)
        } catch {
            jobAIStageActive = false
            let message = error.localizedDescription
            if message == "Cancelled" {
                if suppressTaskFailureUI || queuePersistSuppressed { return }
                if !copyBatchCancelled && seriesContinues() {
                    skipSeriesCopyRequested = false
                    Task { await continueAfterAbortedStep() }
                    return
                }
                finishCancelledBatchIfNeeded()
                return
            }
            handleStepFailure(message)
        }
    }

    private func startFluxPrompt(prompt: String, values: [String: Any]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            foregroundTasks.onFluxPromptReady = { text in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: text)
            }
            foregroundTasks.onJobFinished = { kind, success, error in
                guard kind == "flux_prompt", !resumed else { return }
                resumed = true
                if success {
                    continuation.resume(returning: prompt)
                } else {
                    continuation.resume(throwing: ImageGenError.pipelineFailed(error))
                }
            }
            do {
                _ = try foregroundTasks.startFluxPrompt(
                    prompt: prompt,
                    imagePaths: values["source_image_paths"] as? [String] ?? []
                )
            } catch {
                if !resumed {
                    resumed = true
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func launchGeneration(values: [String: Any]) async {
        let imagegen = config.rawSettings()["imagegen"] as? [String: Any] ?? [:]
        reloadToolbarSettings(from: imagegen)
        let ext = ImageGenDimLimits.outputExtension(from: config.rawSettings())
        let outputPath = ImageGenPathNaming.nextImageGenPath(config: config, ext: ext)
        activeOutputPath = outputPath
        progressiveBrowseOpened = false
        do {
            var payload = try await registry.buildPayload(
                pluginID: activePluginID,
                values: values,
                outputPath: outputPath
            )
            if let plugin = ImageGenPluginCatalog.plugin(pluginID: activePluginID),
               ImageGenPipelineModes.mode(pipelineID: plugin.pipelineID)?.supportsProgressiveImages == true {
                payload["show_progressive_images"] = showProgressiveImages
            }
            // Python ``_launch_generation_job``: pop pad temps / canonical originals from the payload,
            // stamp canonical sources back into the job values, then freeze the copy-cycle EXIF snapshot.
            if let padTemps = payload.removeValue(forKey: "_aspect_pad_temp_paths") as? [String], !padTemps.isEmpty {
                aspectPadTempPaths.append(contentsOf: padTemps)
            }
            let canonicalFromPayload = payload.removeValue(forKey: "_canonical_source_image_paths") as? [String]
            var cycleValues = values
            if let canonical = canonicalFromPayload?.filter({ FileManager.default.isReadableFile(atPath: $0) }),
               !canonical.isEmpty {
                cycleValues["_canonical_source_image_paths"] = canonical
                cycleValues["source_image_path"] = canonical[0]
                cycleValues["source_image_paths"] = canonical
                pendingValues = cycleValues
            }
            if let steps = payload["steps"] as? Int {
                cycleValues["steps"] = steps
            } else if let steps = payload["steps"] as? NSNumber {
                cycleValues["steps"] = steps.intValue
            }
            ImageGenLoraWorkerPayloadEnrich.mergeLoraFields(from: payload, into: &cycleValues)
            pendingValues = cycleValues
            copyCycleValues = cycleValues
            copyCyclePluginID = activePluginID
            if let step = stepRunning {
                let runningDoc = JobStepQueue.buildRunningJobDoc(
                    jobID: activeJobID ?? "",
                    pluginID: activePluginID,
                    function: activeFunction,
                    step: step,
                    outputPath: outputPath,
                    fullPrompt: values["prompt"] as? String ?? "",
                    thumbnailPaths: activeThumbnailPaths
                )
                JobStepPersistence.saveActiveRunning(runningDoc, config: config)
                JobStepPersistence.saveActivePending(stepPendingDoc, config: config)
            }
            progressMessage = "Generating…"
            taskStatusHTML = progressMessage
            if let steps = payload["steps"] as? Int {
                liveStepTotal = steps
            } else if let steps = payload["steps"] as? NSNumber {
                liveStepTotal = steps.intValue
            }
            generationStartTime = Date()
            stepProgressStartTime = Date()
            await refreshActiveJobStatusView()
            await refreshActiveStripView()
            _ = try modelTasks.startGenerate(payload: payload)
            if let activeJobID {
                popQueuedJob(jobID: activeJobID)
            }
            bumpQueueRevision()
        } catch {
            handleStepFailure(error.localizedDescription)
        }
    }

    private func handleGenerateFinished(success: Bool, outputPath: String, error: String) {
        defer {
            skipSeriesCopyRequested = false
        }
        let resolvedOutput = outputPath.isEmpty ? (activeOutputPath ?? "") : outputPath
        if skipSeriesCopyRequested {
            // Python ``_continue_after_aborted_step``: drop the skipped copy's partial output,
            // then run the next pending step immediately (no inter-copy cooldown) or finish the job.
            removePartialOutput(at: resolvedOutput)
            Task { await continueAfterAbortedStep() }
            return
        }

        if success, !resolvedOutput.isEmpty {
            if copyBatchCancelled {
                return
            }
            let exifPluginID = copyCycleExifPluginID
            let exifValues = copyCycleExifValues
            let workerResult = modelTasks.lastGenerateResult
            let exifElapsed = liveGenerationElapsedSeconds()
                ?? stepProgressStartTime.map { Date().timeIntervalSince($0) }
            let fallbackSourcePaths = exifFallbackSourcePaths(from: exifValues)
            onImageGenerated?(resolvedOutput)
            lastError = ""
            progressMessage = "Done"
            Task {
                if copyBatchCancelled { return }
                if let exifElapsed {
                    await recordGenerationTimingRun(values: exifValues, elapsedSeconds: exifElapsed)
                }
                guard !copyBatchCancelled else { return }
                await writeGenerationExif(
                    outputPath: resolvedOutput,
                    pluginID: exifPluginID,
                    values: exifValues,
                    workerResult: workerResult,
                    elapsedSeconds: exifElapsed,
                    fallbackSourcePaths: fallbackSourcePaths
                )
                removeAspectPadTemps()
                guard !copyBatchCancelled else { return }
                await completeSuccessfulGenerationUnit()
            }
            return
        } else {
            lastError = error
            if error == "Cancelled" {
                if suppressTaskFailureUI || queuePersistSuppressed {
                    return
                }
                if !copyBatchCancelled && seriesContinues() {
                    skipSeriesCopyRequested = false
                    Task { await continueAfterAbortedStep() }
                    return
                }
                let pendingCancel = pendingCancelJobID
                let activeID = activeJobID
                if !pendingCancel.isEmpty, let activeID, pendingCancel != activeID {
                    return
                }
                let outputForRepair = resolvedOutput
                Task {
                    await repairCancelledOutputExifReferences(outputPath: outputForRepair)
                    finishCopyBatch(cancelled: true)
                }
                return
            }
            removePartialOutput(at: resolvedOutput)
            if !suppressTaskFailureUI {
                let message = error.isEmpty ? "Image generation failed." : String(error.prefix(4000))
                StyledMessageDialog.showCritical(title: "Generation failed", message: message)
            }
            let err = error.isEmpty ? "Image generation failed." : error
            if requeueFailedActiveJobAtHead(errorMessage: err) {
                return
            }
            finishCopyBatch(cancelled: false)
            return
        }
    }

    private func completeSuccessfulGenerationUnit() async {
        guard !copyBatchCancelled else { return }
        completeRunningStepAfterCopy()
        if finishCurrentUnitAndMaybeQuit() {
            return
        }
        if holdJobQueue {
            if seriesContinues() {
                _ = demoteActiveRemainingToQueue()
            } else {
                finishActiveJob(cancelled: false)
            }
            scheduleUnloadImageModelForQueueHold()
            return
        }
        if seriesContinues() {
            scheduleCopyCooldownThen { await self.promoteAndRunNextStep() }
        } else if activeJobID != nil {
            finishActiveJob(cancelled: false)
        } else {
            Task { await startNextQueuedJobIfIdle() }
        }
    }

    /// Port of ``ImageGenController._series_continues_after_copy_success``.
    private func seriesContinues() -> Bool {
        guard copyBatchActive, !copyBatchCancelled else { return false }
        if activeJobHeld() {
            _ = yieldActiveBatchIfNotNextToRun()
            return false
        }
        if JobStepQueue.isSeriesContinuousCopies(copiesTotal) { return true }
        if JobStepQueue.pendingStepCount(stepPendingDoc) <= 0 { return false }
        if yieldActiveBatchIfNotNextToRun() { return false }
        return true
    }

    private func continueAfterAbortedStep() async {
        completeRunningStepAfterCopy()
        skipSeriesCopyInFlight = false
        resetActiveJobProgressTracking()
        if holdJobQueue {
            if seriesContinues() {
                _ = demoteActiveRemainingToQueue()
            } else {
                finishCopyBatch(cancelled: false)
            }
            scheduleUnloadImageModelForQueueHold()
            return
        }
        if seriesContinues() {
            await promoteAndRunNextStep()
        } else {
            finishCopyBatch(cancelled: false)
        }
    }

    private func finishCancelledBatchIfNeeded() {
        guard copyBatchCancelled else { return }
        if modelTasks.isBusy || jobAIStageActive {
            return
        }
        finishCopyBatch(cancelled: true)
    }

    private func finishActiveJob(cancelled: Bool) {
        finishCopyBatch(cancelled: cancelled)
    }

    private func finishCopyBatch(cancelled: Bool = false) {
        guard activeJobID != nil || isProcessing || stepRunning != nil || stepPendingDoc != nil
            || copyBatchCancelled || jobAIStageActive else {
            return
        }
        let cancelledJobID = cancelled ? (activeJobID ?? pendingCancelJobID) : ""
        let finishedJobID = activeJobID
        cooldownTask?.cancel()
        cooldownDisplayTask?.cancel()
        cooldownSecondsRemaining = 0
        if cancelled, !cancelledJobID.isEmpty {
            removeCancelledJobFromQueue(jobID: cancelledJobID)
        } else if let finishedJobID, !finishedJobID.isEmpty {
            let before = queue.jobs.count
            queue.jobs.removeAll { $0.jobID == finishedJobID }
            if queue.jobs.count != before, !queuePersistSuppressed {
                persistQueue()
            }
            if selectedJobID == finishedJobID {
                selectJob(id: queue.jobs.first?.jobID)
            }
        }
        removeAspectPadTemps()
        cleanupInfillBatchAssets()
        clearCopyCycleExifSnapshot()
        activeJobID = nil
        activeJobNumber = nil
        isProcessing = false
        progressMessage = ""
        taskStatusHTML = ""
        stopLiveStatusTimer()
        activeStatusView = nil
        activeStripView = ActiveJobStripStatusView()
        resetActiveJobProgressTracking()
        generationStartTime = nil
        skipSeriesCopyInFlight = false
        progressivePreviewPath = nil
        activeOutputPath = nil
        progressiveBrowseOpened = false
        activeThumbnailPaths = []
        activeJobCardThumbnailPathsCache = []
        stepRunning = nil
        stepPendingDoc = nil
        copyBatchActive = false
        copiesTotal = 0
        copiesDone = 0
        jobAIStageActive = false
        copyBatchCancelled = false
        pendingCancelJobID = ""
        if !queuePersistSuppressed {
            JobStepPersistence.saveActiveRunning(nil, config: config)
            JobStepPersistence.saveActivePending(nil, config: config)
            persistQueue()
        }
        bumpQueueRevision()
        if !holdJobQueue, !queueAdvanceSuppressed, !startupQueueHold {
            if !queue.jobs.isEmpty, jobCooldownSeconds() > 0 {
                scheduleJobCooldownThen { await self.startNextQueuedJobIfIdle() }
            } else {
                Task { await startNextQueuedJobIfIdle() }
            }
        }
        maybeQuitAfterCurrentWorker()
    }

    private func removeCancelledJobFromQueue(jobID: String) {
        guard !jobID.isEmpty else { return }
        let before = queue.jobs.count
        queue.jobs.removeAll { $0.jobID == jobID }
        if queue.jobs.count != before {
            bumpQueueRevision()
        }
    }

    private func handleStepFailure(_ message: String) {
        if suppressTaskFailureUI || queuePersistSuppressed { return }
        lastError = message
        progressMessage = "Failed"
        taskStatusHTML = progressMessage
        if requeueFailedActiveJobAtHead(errorMessage: message) {
            return
        }
        if let jobID = activeJobID,
           let index = queue.jobs.firstIndex(where: { $0.jobID == jobID }) {
            markQueuedJobFailed(at: index, message: message)
        }
        finishOrAbortQueuedJobStart()
    }

    private func isRunnableQueuedJob(_ job: ImageGenQueuedJob) -> Bool {
        if job.held || job.inError { return false }
        return job.statusHTML == "Queued" || job.statusLabel == "Queued"
    }

    private func markQueuedJobFailed(at index: Int, message: String) {
        guard queue.jobs.indices.contains(index) else { return }
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Job failed."
            : message
        queue.jobs[index].statusHTML = "Queued"
        queue.jobs[index].held = false
        queue.jobs[index].inError = true
        queue.jobs[index].errorMessage = msg
        if message.contains("No MFLUX CLI mapping") {
            queue.jobs[index].pluginUnavailable = true
        }
        Task {
            await refreshQueuedJobStatus(at: index)
            persistQueue()
            bumpQueueRevision()
        }
    }

    /// Port of ``ImageGenController._demote_active_remaining_to_queue``.
    @discardableResult
    private func demoteActiveRemainingToQueue() -> Bool {
        guard !copyBatchCancelled else { return false }
        let jobID = activeJobID ?? ""
        guard !jobID.isEmpty, !activePluginID.isEmpty else { return false }
        let pendingCount = JobStepQueue.pendingStepCount(stepPendingDoc)
        let continuous = JobStepQueue.isSeriesContinuousCopies(copiesTotal)
            || JobStepQueue.pendingDocIsContinuous(stepPendingDoc, runningStep: stepRunning)
        if pendingCount <= 0, stepRunning == nil, !continuous { return false }
        guard let collected = collectActiveRemainingStepsForDemote() else { return false }

        let (steps, submitValues, copies) = collected
        let storedPrompt = (stepPendingDoc?["display"] as? [String: Any])?["full_prompt"] as? String ?? ""
        let fullPrompt = JobStepQueue.resolvedFullPrompt(
            stored: storedPrompt,
            values: submitValues,
            steps: steps,
            statusView: activeStatusView
        )
        let thumbs = activeThumbnailPaths.isEmpty
            ? (queue.jobs.first(where: { $0.jobID == jobID })?.thumbnailPaths ?? [])
            : activeThumbnailPaths
        let built = buildQueueStatusView(
            pluginID: activePluginID,
            function: activeFunction,
            values: submitValues,
            copiesTotal: copies,
            running: false
        )
        let held = activeJobHeld()
        let insertAt = max(0, min(activeDisplayIndex, queue.jobs.count))

        if let index = queue.jobs.firstIndex(where: { $0.jobID == jobID }) {
            queue.jobs[index].pluginID = activePluginID
            queue.jobs[index].function = activeFunction
            queue.jobs[index].pluginUnavailable = false
            queue.jobs[index].values = submitValues
            queue.jobs[index].copiesTotal = copies
            queue.jobs[index].steps = steps
            queue.jobs[index].fullPrompt = fullPrompt
            queue.jobs[index].thumbnailPaths = thumbs
            queue.jobs[index].held = held
            queue.jobs[index].inError = false
            queue.jobs[index].errorMessage = ""
            queue.jobs[index].statusHTML = "Queued"
            queue.jobs[index].statusView = built.statusView
            if let activeJobNumber {
                queue.jobs[index].jobNumber = activeJobNumber
            }
        } else {
            let job = ImageGenQueuedJob(
                jobID: jobID,
                pluginID: activePluginID,
                function: activeFunction,
                values: submitValues,
                copiesTotal: copies,
                statusHTML: "Queued",
                fullPrompt: fullPrompt,
                thumbnailPaths: thumbs,
                steps: steps,
                statusView: built.statusView,
                jobNumber: activeJobNumber,
                held: held
            )
            queue.jobs.insert(job, at: insertAt)
        }

        activeDisplayIndex = 0
        finalizeRequeuedActiveJob()
        Task {
            guard let index = queue.jobs.firstIndex(where: { $0.jobID == jobID }) else { return }
            await refreshQueuedJobStatus(at: index)
            persistQueue()
            bumpQueueRevision()
        }
        return true
    }

    /// After the in-flight copy of a held queue finishes, demote when idle between copies.
    @discardableResult
    private func applyQueueHoldAfterCurrentCopy() -> Bool {
        guard holdJobQueue else { return false }
        if quitAfterCurrentWorker, !deferredQuitWaitAllJobs { return false }
        let copyInFlight = stepRunning != nil || jobAIStageActive || foregroundTasks.isBusy
        guard !copyInFlight else { return false }
        guard demoteActiveRemainingToQueue() else { return false }
        scheduleUnloadImageModelForQueueHold()
        return true
    }

    private func collectActiveRemainingStepsForDemote() -> (steps: [[String: Any]], values: [String: Any], copies: Int)? {
        guard !activePluginID.isEmpty else { return nil }
        let continuous = JobStepQueue.isSeriesContinuousCopies(copiesTotal)
            || JobStepQueue.pendingDocIsContinuous(stepPendingDoc, runningStep: stepRunning)
        var steps: [[String: Any]] = []
        if let stepRunning {
            steps.append(stepRunning)
        }
        if let raw = stepPendingDoc?["steps"] as? [[String: Any]] {
            steps.append(contentsOf: raw)
        }
        if steps.isEmpty, continuous {
            var template = pendingValues
            template["copies"] = JobStepQueue.seriesContinuousCopies
            if let materialized = try? JobStepQueue.materializeSteps(
                pluginID: activePluginID,
                templateValues: template,
                copiesTotal: JobStepQueue.seriesContinuousCopies
            ), !materialized.isEmpty {
                steps = materialized
            } else if let templateStep = stepPendingDoc?[JobStepQueue.continuousTemplateKey] as? [String: Any] {
                steps = [[
                    "step_id": JobStepQueue.newStepID(),
                    "values": JobStepQueue.mergeStepIntoValues(templateStep),
                    "needs_ai": false,
                ]]
            } else {
                steps = [[
                    "step_id": JobStepQueue.newStepID(),
                    "values": template,
                    "needs_ai": false,
                ] as [String: Any]]
            }
        }
        guard !steps.isEmpty else { return nil }
        let copies = continuous ? JobStepQueue.seriesContinuousCopies : steps.count
        JobStepQueue.stampSeriesCopiesOnSteps(&steps, copies: copies)
        var values = JobStepQueue.mergeStepIntoValues(steps[0])
        values["copies"] = copies
        return (steps, values, copies)
    }

    @discardableResult
    private func requeueFailedActiveJobAtHead(errorMessage: String) -> Bool {
        let jobID = activeJobID ?? ""
        guard !jobID.isEmpty, !activePluginID.isEmpty else { return false }
        let msg = errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Job failed."
            : errorMessage
        guard let collected = collectActiveRemainingStepsForRequeue() else { return false }

        let (steps, values, copies) = collected
        var submitValues = values
        submitValues["copies"] = copies
        let fullPrompt = JobStepQueue.resolvedFullPrompt(
            stored: (stepPendingDoc?["display"] as? [String: Any])?["full_prompt"] as? String ?? "",
            values: submitValues,
            steps: steps,
            statusView: activeStatusView
        )
        let thumbs = activeThumbnailPaths.isEmpty
            ? (queue.jobs.first(where: { $0.jobID == jobID })?.thumbnailPaths ?? [])
            : activeThumbnailPaths
        let insertAt = max(0, min(activeDisplayIndex, queue.jobs.count))

        if let index = queue.jobs.firstIndex(where: { $0.jobID == jobID }) {
            queue.jobs[index].pluginID = activePluginID
            queue.jobs[index].function = activeFunction
            queue.jobs[index].pluginUnavailable = false
            queue.jobs[index].values = submitValues
            queue.jobs[index].copiesTotal = copies
            queue.jobs[index].steps = steps
            queue.jobs[index].fullPrompt = fullPrompt
            queue.jobs[index].thumbnailPaths = thumbs
            queue.jobs[index].held = false
            queue.jobs[index].inError = true
            queue.jobs[index].errorMessage = msg
            queue.jobs[index].statusHTML = "Queued"
            if let activeJobNumber {
                queue.jobs[index].jobNumber = activeJobNumber
            }
            Task {
                await refreshQueuedJobStatus(at: index)
                finalizeRequeuedActiveJob()
            }
            return true
        }

        let job = ImageGenQueuedJob(
            jobID: jobID,
            pluginID: activePluginID,
            function: activeFunction,
            values: submitValues,
            copiesTotal: copies,
            statusHTML: "Queued",
            fullPrompt: fullPrompt,
            thumbnailPaths: thumbs,
            steps: steps,
            jobNumber: activeJobNumber,
            inError: true,
            errorMessage: msg
        )
        queue.jobs.insert(job, at: insertAt)
        Task {
            await refreshQueuedJobStatus(at: insertAt)
            finalizeRequeuedActiveJob()
        }
        return true
    }

    private func finalizeRequeuedActiveJob() {
        cooldownTask?.cancel()
        cooldownDisplayTask?.cancel()
        cooldownSecondsRemaining = 0
        removeAspectPadTemps()
        clearCopyCycleExifSnapshot()
        activeJobID = nil
        activeJobNumber = nil
        isProcessing = false
        progressMessage = ""
        taskStatusHTML = ""
        stopLiveStatusTimer()
        activeStatusView = nil
        activeStripView = ActiveJobStripStatusView()
        resetActiveJobProgressTracking()
        generationStartTime = nil
        skipSeriesCopyInFlight = false
        progressivePreviewPath = nil
        activeOutputPath = nil
        progressiveBrowseOpened = false
        activeThumbnailPaths = []
        activeJobCardThumbnailPathsCache = []
        stepRunning = nil
        stepPendingDoc = nil
        copyBatchActive = false
        copiesTotal = 0
        copiesDone = 0
        jobAIStageActive = false
        copyBatchCancelled = false
        pendingCancelJobID = ""
        activePluginID = ""
        activeFunction = "create"
        pendingValues = [:]
        if !queuePersistSuppressed {
            JobStepPersistence.saveActiveRunning(nil, config: config)
            JobStepPersistence.saveActivePending(nil, config: config)
            persistQueue()
        }
        bumpQueueRevision()
        if !holdJobQueue, !queueAdvanceSuppressed, !startupQueueHold {
            if !queue.jobs.isEmpty, jobCooldownSeconds() > 0 {
                scheduleJobCooldownThen { await self.startNextQueuedJobIfIdle() }
            } else {
                Task { await startNextQueuedJobIfIdle() }
            }
        }
    }

    private func collectActiveRemainingStepsForRequeue() -> (steps: [[String: Any]], values: [String: Any], copies: Int)? {
        guard !activePluginID.isEmpty else { return nil }
        let pendingCount = JobStepQueue.pendingStepCount(stepPendingDoc)
        let continuous = JobStepQueue.isSeriesContinuousCopies(copiesTotal)
        if pendingCount <= 0, stepRunning == nil, !continuous { return nil }

        var steps: [[String: Any]] = []
        if let stepRunning {
            steps.append(stepRunning)
        }
        if let raw = stepPendingDoc?["steps"] as? [[String: Any]] {
            steps.append(contentsOf: raw)
        }
        if steps.isEmpty, continuous {
            return nil
        }
        guard !steps.isEmpty else { return nil }

        var values = pendingValues
        let copies = JobStepQueue.normalizeCopies(values["copies"] ?? copiesTotal)
        values["copies"] = copies
        return (steps, values, copies)
    }

    private func finishOrAbortQueuedJobStart() {
        if let activeJobID, queuedJob(byID: activeJobID) != nil {
            abortQueuedJobStart()
        } else {
            finishActiveJob(cancelled: false)
        }
    }

    private func queuedJob(byID jobID: String) -> ImageGenQueuedJob? {
        queue.jobs.first { $0.jobID == jobID }
    }

    @discardableResult
    private func popQueuedJob(jobID: String) -> Bool {
        guard let index = queue.jobs.firstIndex(where: { $0.jobID == jobID }) else { return false }
        queue.jobs.remove(at: index)
        persistQueue()
        bumpQueueRevision()
        return true
    }

    /// Reset after a queued job failed to start; queue row stays in place (Python ``_abort_queued_job_start``).
    private func abortQueuedJobStart() {
        resetActiveGenerationStateForQueueRetry()
        if !queuePersistSuppressed {
            JobStepPersistence.saveActiveRunning(nil, config: config)
            JobStepPersistence.saveActivePending(nil, config: config)
            persistQueue()
        }
        bumpQueueRevision()
        Task { await startNextQueuedJobIfIdle() }
    }

    private func processNextIfIdle() {
        Task { await startNextQueuedJobIfIdle() }
    }

    private func isMultistepSeriesJob() -> Bool {
        copyBatchActive && copiesTotal > 1
    }

    private func copyCooldownSeconds() -> Int {
        guard isMultistepSeriesJob() else { return 0 }
        return ImageGenDimLimits.appInterCopyCooldownSeconds(settings: config.rawSettings())
    }

    private func jobCooldownSeconds() -> Int {
        ImageGenDimLimits.appJobCooldownSeconds(settings: config.rawSettings())
    }

    private func scheduleCopyCooldownThen(_ action: @escaping () async -> Void) {
        cooldownBeforeNextJob = false
        scheduleCooldownTimer(seconds: copyCooldownSeconds(), action: action)
    }

    private func scheduleJobCooldownThen(_ action: @escaping () async -> Void) {
        cooldownBeforeNextJob = true
        scheduleCooldownTimer(seconds: jobCooldownSeconds(), action: action)
    }

    private func scheduleCooldownTimer(seconds: Int, action: @escaping () async -> Void) {
        cooldownTask?.cancel()
        cooldownDisplayTask?.cancel()
        enterCopyCooldownAfterSuccess()
        let ms = max(0, seconds * 1000)
        cooldownSecondsRemaining = max(0, seconds)
        lastCooldownUISecond = nil
        Task { await refreshActiveStripView(force: true) }
        cooldownDisplayTask = Task {
            while cooldownSecondsRemaining > 0, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                cooldownSecondsRemaining = max(0, cooldownSecondsRemaining - 1)
                await refreshActiveStripView()
            }
        }
        cooldownTask = Task {
            if ms > 0 {
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            }
            guard !Task.isCancelled else { return }
            await onCooldownElapsed(action)
        }
    }

    /// Port of Python ``_on_copy_cooldown_elapsed`` (shared by the timer and ``skipCopyCooldown``).
    private func onCooldownElapsed(_ action: () async -> Void) async {
        let afterJob = cooldownBeforeNextJob
        cooldownSecondsRemaining = 0
        cooldownBeforeNextJob = false
        lastCooldownUISecond = nil
        if afterJob {
            // No active job here: clear the cooldown strip even when the queue stays held.
            await refreshActiveStripView(force: true)
            if quitAfterCurrentWorker, !deferredQuitWaitAllJobs {
                maybeQuitAfterCurrentWorker()
                return
            }
            if holdJobQueue || queueAdvanceSuppressed || startupQueueHold {
                return
            }
            await action()
            return
        }
        if quitAfterCurrentWorker, !deferredQuitWaitAllJobs {
            finishCopyBatch(cancelled: false)
            maybeQuitAfterCurrentWorker()
            return
        }
        if copyBatchCancelled {
            finishCopyBatch(cancelled: true)
            return
        }
        if holdJobQueue {
            if seriesContinues() {
                _ = demoteActiveRemainingToQueue()
            } else {
                finishActiveJob(cancelled: false)
            }
            scheduleUnloadImageModelForQueueHold()
            return
        }
        await action()
    }

    /// Port of ``ImageGenController._activate_continuous_series_pending_doc``.
    private func activateContinuousSeriesPendingDoc(
        _ doc: inout [String: Any],
        templateStep: [String: Any]? = nil
    ) {
        let template: [String: Any]?
        if let templateStep {
            template = templateStep
        } else if let steps = doc["steps"] as? [[String: Any]], let first = steps.first {
            template = first
        } else if let stepRunning {
            template = stepRunning
        } else {
            template = nil
        }
        guard let template else { return }
        doc[JobStepQueue.continuousModeKey] = true
        doc[JobStepQueue.continuousTemplateKey] = template
    }

    /// Port of ``ImageGenController._append_continuous_pending_step`` (before ``_promote_next_step_to_running``).
    private func appendContinuousPendingStepIfNeeded(_ doc: inout [String: Any]) {
        guard JobStepQueue.isSeriesContinuousCopies(copiesTotal) else { return }
        guard JobStepQueue.pendingStepCount(doc) <= 0 else { return }
        guard let template = doc[JobStepQueue.continuousTemplateKey] as? [String: Any] else { return }
        doc = JobStepQueue.appendContinuousStep(to: doc, templateStep: template)
    }

    private func appendPendingSteps(count: Int) {
        guard var doc = stepPendingDoc, count > 0 else { return }
        Task {
            do {
                let steps = try await registry.materializeSteps(
                    pluginID: activePluginID,
                    values: pendingValues,
                    copies: count
                )
                var existing = doc["steps"] as? [[String: Any]] ?? []
                existing.append(contentsOf: steps)
                doc["steps"] = existing
                stepPendingDoc = doc
                persistStepState()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func trimPendingSteps(count: Int) {
        guard var doc = stepPendingDoc, count > 0 else { return }
        var steps = doc["steps"] as? [[String: Any]] ?? []
        if count >= steps.count {
            steps = []
        } else {
            steps = Array(steps.dropLast(count))
        }
        doc["steps"] = steps
        stepPendingDoc = doc
    }

    private func clearPendingSteps() {
        guard var doc = stepPendingDoc else { return }
        doc["steps"] = []
        stepPendingDoc = doc
    }

    private func buildActiveQueuedJob() -> ImageGenQueuedJob? {
        guard let activeJobID else { return nil }
        return ImageGenQueuedJob(
            jobID: activeJobID,
            pluginID: activePluginID,
            function: activeFunction,
            values: pendingValues,
            copiesTotal: copiesTotal,
            statusHTML: taskStatusHTML,
            fullPrompt: pendingValues["prompt"] as? String ?? "",
            thumbnailPaths: activeThumbnailPaths,
            steps: stepPendingDoc?["steps"] as? [[String: Any]] ?? [],
            jobNumber: activeJobNumber,
            held: activeJobHeld()
        )
    }

    private func persistQueue() {
        if queuePersistSuppressed { return }
        queue.activeDisplayIndex = activeDisplayIndex
        JobStepPersistence.saveQueue(queue, config: config)
    }

    private func persistStepState() {
        if queuePersistSuppressed { return }
        let runningDoc: [String: Any]?
        if let stepRunning {
            runningDoc = JobStepPersistence.loadActiveRunning(config: config)
                ?? JobStepQueue.buildRunningJobDoc(
                    jobID: activeJobID ?? "",
                    pluginID: activePluginID,
                    function: activeFunction,
                    step: stepRunning,
                    outputPath: activeOutputPath ?? "",
                    fullPrompt: pendingValues["prompt"] as? String ?? "",
                    thumbnailPaths: activeThumbnailPaths
                )
        } else {
            runningDoc = nil
        }
        JobStepPersistence.persistStepJobFiles(
            running: runningDoc,
            pending: stepPendingDoc,
            queue: queueWithActiveDisplayIndex(),
            config: config
        )
    }

    private func bumpQueueRevision() {
        if dialogBuildPauseCount == 0 {
            queueRevision += 1
        }
        bumpStripUI()
    }

    /// Always refresh job-pane / strip SwiftUI (not blocked by dialog build pause).
    private func bumpStripUI() {
        lastStripPublishKey = stripPublishKey()
        onQueueChanged?()
    }

    /// Progress ticks redraw the bars in place. Show, hide, or a row-structure change
    /// refreshes the jobs pane so its height can follow the strip.
    private func publishActiveStrip(preferLiveFields: Bool) {
        let key = stripPublishKey()
        if preferLiveFields, key == lastStripPublishKey {
            let strip = activeStripView
            for sink in stripLiveSinks.values {
                sink(strip)
            }
            return
        }
        bumpStripUI()
    }

    private func stripPublishKey() -> String {
        let visible = isProcessing || cooldownSecondsRemaining > 0
        return "\(visible)|\(activeStripView.structureKey())"
    }

    /// Port of ``ImageGenController.task_status_display_needs_refresh``.
    private func stripDisplayNeedsRefresh() -> Bool {
        guard cooldownSecondsRemaining > 0 else { return true }
        return cooldownSecondsRemaining != lastCooldownUISecond
    }

    private func markStripDisplayRefreshed() {
        if cooldownSecondsRemaining > 0 {
            lastCooldownUISecond = cooldownSecondsRemaining
        } else {
            lastCooldownUISecond = nil
        }
    }

    private func rebuildActiveStripViewLocally(includeQueueJobsRow: Bool = false) {
        guard isProcessing || cooldownSecondsRemaining > 0 else {
            activeStripView = ActiveJobStripStatusView()
            return
        }
        let timing = currentTimingForDisplay()
        let elapsed = timing.elapsed ?? wallClockElapsedSeconds(inCooldown: cooldownSecondsRemaining > 0) ?? 0
        activeStripView = ActiveJobStripBuilder.build(
            elapsedSeconds: elapsed,
            estimateSeconds: timing.estimate,
            step: liveStep,
            stepTotal: liveStepTotal,
            stepsLabel: jobAIStageActive ? "AI:" : "Steps:",
            cooldownRemaining: cooldownSecondsRemaining,
            completedSeries: copiesDone,
            totalSeries: copiesTotal > 1 ? copiesTotal : nil,
            totalQueueJobs: includeQueueJobsRow ? queueSnapshot().count : nil
        )
    }

    private func wireBridgeCallbacks() {
        modelTasks.onJobProcessingStarted = { [weak self] kind in
            guard let self else { return }
            if kind == "generate" {
                self.progressMessage = "Generating…"
                self.taskStatusHTML = self.progressMessage
                Task { await self.beginGenerationProgressTracking(values: self.pendingValues) }
                self.rebuildActiveStripViewLocally()
                self.publishActiveStrip(preferLiveFields: true)
            }
        }
        modelTasks.onProgress = { [weak self] message in
            guard let self else { return }
            if let step = self.intFromAny(message["step"]) {
                self.updateLiveStepProgress(step: step, stepTotal: message["step_total"])
            } else if let total = self.intFromAny(message["step_total"])
                        ?? self.intFromAny(message["total_steps"]) {
                self.liveStepTotal = total
            }
            if let path = self.progressMessagePath(from: message),
               self.showProgressiveImages {
                self.progressivePreviewPath = path
                let step = self.intFromAny(message["step"]) ?? -1
                let stepTotal = self.intFromAny(message["step_total"]) ?? self.liveStepTotal
                if step != 0 {
                    let isFinal = step > 0 && stepTotal > 0 && step >= stepTotal
                    let forceEnterBrowse = isFinal || !self.progressiveBrowseOpened
                    self.onProgressivePreview?(path, forceEnterBrowse, step, stepTotal)
                }
            }
            _ = self.snapshotLiveTiming(inCooldown: self.cooldownSecondsRemaining > 0)
            self.rebuildActiveStripViewLocally()
            self.publishActiveStrip(preferLiveFields: true)
        }
        modelTasks.onGenerateFinished = { [weak self] success, outputPath, error in
            self?.handleGenerateFinished(success: success, outputPath: outputPath, error: error)
            self?.scheduleUnloadImageModelForQueueHold()
        }
    }

    private func unloadModelsWhenQueueHeldEnabled() -> Bool {
        config.bool(forKey: "imagegen_unload_models_when_queue_held", default: false)
    }

    private func scheduleUnloadImageModelForQueueHold() {
        guard holdJobQueue, unloadModelsWhenQueueHeldEnabled() else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000)
            self?.maybeUnloadImageModelForQueueHold()
        }
    }

    private func maybeUnloadImageModelForQueueHold() {
        guard holdJobQueue, unloadModelsWhenQueueHeldEnabled() else { return }
        if jobAIStageActive || modelTasks.isBusy || foregroundTasks.isBusy || cooldownSecondsRemaining > 0 {
            return
        }
        _ = modelTasks.unloadImageModel()
    }

    private func mutateImagegen(_ mutate: (inout [String: Any]) -> Void) {
        var imagegen = config.rawSettings()["imagegen"] as? [String: Any] ?? [:]
        mutate(&imagegen)
        config.updateSetting("imagegen", value: imagegen)
    }

    private func resetLiveQueueProgress() {
        liveStep = 0
        liveStepTotal = 0
        liveEstimateSeconds = nil
        stepSecondsPerStep = nil
        generationTimingKey = nil
        historicalAvgTotalSeconds = nil
        stepProgressCompletedAt = nil
    }

    private func resetActiveJobProgressTracking() {
        resetLiveQueueProgress()
        stepProgressStartTime = nil
        frozenElapsedSeconds = nil
    }

    private func beginGenerationProgressTracking(values: [String: Any]) async {
        let now = Date()
        stepProgressStartTime = now
        generationStartTime = now
        liveStep = 0
        liveEstimateSeconds = nil
        stepSecondsPerStep = nil
        stepProgressCompletedAt = nil
        if let steps = values["steps"] as? Int {
            liveStepTotal = steps
        } else if let steps = values["steps"] as? NSNumber {
            liveStepTotal = steps.intValue
        }
        guard !activePluginID.isEmpty else { return }
        let timing = GenerationTimingKeyBuilder.build(
            pluginID: activePluginID,
            values: values,
            dataDirectory: config.dataDirectory
        )
        generationTimingKey = timing.key
        historicalAvgTotalSeconds = timing.averageSeconds
        _ = snapshotLiveTiming(inCooldown: cooldownSecondsRemaining > 0)
        rebuildActiveStripViewLocally()
        publishActiveStrip(preferLiveFields: true)
    }

    private func updateLiveStepProgress(step: Int, stepTotal: Any?) {
        let total = intFromAny(stepTotal) ?? liveStepTotal
        if step > 0, stepProgressStartTime != nil, let elapsed = liveGenerationElapsedSeconds() {
            stepSecondsPerStep = elapsed / Double(step)
        }
        liveStep = step
        liveStepTotal = total
        if step >= total, total > 0, stepProgressCompletedAt == nil {
            stepProgressCompletedAt = Date()
        }
        if step > 0 {
            progressMessage = "Step \(step)"
            taskStatusHTML = progressMessage
        }
    }

    private func liveGenerationElapsedSeconds() -> Double? {
        guard let start = stepProgressStartTime else { return nil }
        if let completed = stepProgressCompletedAt {
            return completed.timeIntervalSince(start)
        }
        return Date().timeIntervalSince(start)
    }

    private func wallClockElapsedSeconds(inCooldown: Bool) -> Double? {
        guard let start = stepProgressStartTime ?? generationStartTime else { return nil }
        if inCooldown, let frozen = frozenElapsedSeconds {
            return frozen
        }
        return Date().timeIntervalSince(start)
    }

    private static func estimateRemainingSeconds(
        elapsed: Double,
        completedSteps: Int,
        totalSteps: Int,
        secondsPerStep: Double?
    ) -> Double? {
        guard completedSteps > 0,
              totalSteps > 0,
              completedSteps < totalSteps,
              let secondsPerStep,
              secondsPerStep > 0 else {
            return nil
        }
        return max(0, Double(totalSteps) * secondsPerStep - elapsed)
    }

    @discardableResult
    private func snapshotLiveTiming(inCooldown: Bool = false) -> (elapsed: Double?, estimate: Double?) {
        if inCooldown {
            if let frozen = frozenElapsedSeconds {
                liveEstimateSeconds = nil
                return (frozen, nil)
            }
            return (nil, nil)
        }
        guard let elapsed = liveGenerationElapsedSeconds() else {
            return (nil, nil)
        }
        var estimate: Double?
        if liveStep > 0, liveStepTotal > 0 {
            estimate = Self.estimateRemainingSeconds(
                elapsed: elapsed,
                completedSteps: liveStep,
                totalSteps: liveStepTotal,
                secondsPerStep: stepSecondsPerStep
            )
        } else if let average = historicalAvgTotalSeconds, average > 0 {
            estimate = max(0, average - elapsed)
        }
        liveEstimateSeconds = estimate
        return (elapsed, estimate)
    }

    private func elapsedSeconds() -> Double? {
        let inCooldown = cooldownSecondsRemaining > 0
        let (elapsed, _) = snapshotLiveTiming(inCooldown: inCooldown)
        if let elapsed { return elapsed }
        return wallClockElapsedSeconds(inCooldown: inCooldown)
    }

    private func currentTimingForDisplay() -> (elapsed: Double?, estimate: Double?) {
        let inCooldown = cooldownSecondsRemaining > 0
        let snapshot = snapshotLiveTiming(inCooldown: inCooldown)
        if snapshot.elapsed != nil {
            return snapshot
        }
        let elapsed = wallClockElapsedSeconds(inCooldown: inCooldown)
        return (elapsed, inCooldown ? nil : liveEstimateSeconds)
    }

    private func recordGenerationTimingRun(values: [String: Any], elapsedSeconds: Double) async {
        guard elapsedSeconds > 0 else { return }
        let timingKey = GenerationTimingKeyBuilder.build(
            pluginID: activePluginID,
            values: values,
            dataDirectory: config.dataDirectory
        ).key ?? generationTimingKey
        if let key = timingKey {
            GenerationTimingStats.recordRun(
                key: key,
                elapsedSeconds: elapsedSeconds,
                dataDirectory: config.dataDirectory
            )
        } else if let key = generationTimingKey {
            GenerationTimingStats.recordRun(
                key: key,
                elapsedSeconds: elapsedSeconds,
                dataDirectory: config.dataDirectory
            )
        }
    }

    private func enterCopyCooldownAfterSuccess() {
        let finalElapsed = liveGenerationElapsedSeconds()
            ?? stepProgressStartTime.map { Date().timeIntervalSince($0) }
        frozenElapsedSeconds = finalElapsed
        stepProgressStartTime = nil
        resetLiveQueueProgress()
    }

    /// Port of ``ImageGenController._active_job_card_thumbnail_paths``.
    private func activeJobCardThumbnailPaths() -> [String] {
        if !activeJobCardThumbnailPathsCache.isEmpty {
            return activeJobCardThumbnailPathsCache
        }
        return cardThumbnailPaths(activeThumbnailPaths)
    }

    private func cardThumbnailPaths(_ paths: [String]) -> [String] {
        let excluded = generationOutputPathsExcludedFromCard()
        return paths.filter { path in
            let norm = normalizedImagePath(path)
            return !norm.isEmpty
                && FileManager.default.fileExists(atPath: norm)
                && !excluded.contains(norm)
        }
    }

    private func generationOutputPathsExcludedFromCard() -> Set<String> {
        var excluded = Set<String>()
        if let path = progressivePreviewPath, !path.isEmpty {
            excluded.insert(normalizedImagePath(path))
        }
        if let path = activeOutputPath, !path.isEmpty {
            excluded.insert(normalizedImagePath(path))
        }
        if let running = JobStepPersistence.loadActiveRunning(config: config),
           let output = running["output_path"] as? String, !output.isEmpty {
            excluded.insert(normalizedImagePath(output))
        }
        return excluded
    }

    private func normalizedImagePath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    private func pathsAssociatedWithActiveGeneration() -> Set<String> {
        var paths = Set<String>()
        if let activeOutputPath, !activeOutputPath.isEmpty {
            paths.insert(normalizedImagePath(activeOutputPath))
        }
        if let progressivePreviewPath, !progressivePreviewPath.isEmpty {
            paths.insert(normalizedImagePath(progressivePreviewPath))
        }
        for path in activeThumbnailPaths where !path.isEmpty {
            paths.insert(normalizedImagePath(path))
        }
        if let sourcePaths = pendingValues["source_image_paths"] as? [String] {
            for path in sourcePaths where !path.isEmpty {
                paths.insert(normalizedImagePath(path))
            }
        }
        return paths
    }

    private func refreshAllQueuedJobStatusViews() async {
        for index in queue.jobs.indices {
            await refreshQueuedJobStatus(at: index)
        }
        persistQueue()
        bumpQueueRevision()
    }

    private func queueStatusPreviewOutputPath() -> String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("prowser_imagegen")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (dir as NSString).appendingPathComponent(".__imagegen_queue_preview__.png")
    }

    /// Port of ``refresh_queued_job_status`` in ``model_task_queue.py``.
    private func refreshQueuedJobStatus(at index: Int) async {
        guard queue.jobs.indices.contains(index) else { return }
        let jobID = queue.jobs[index].jobID
        guard var job = queuedJob(byID: jobID) else { return }

        if job.pluginUnavailable || ImageGenPluginCatalog.plugin(pluginID: job.pluginID) == nil {
            let built = buildQueueStatusView(
                pluginID: job.pluginID,
                function: job.function,
                values: job.values,
                copiesTotal: job.copiesTotal,
                pluginUnavailable: true
            )
            job.statusView = built.statusView
            job.thumbnailPaths = cardThumbnailPaths(built.thumbnailPaths)
            job.fullPrompt = built.fullPrompt
            job.referencesInvalid = built.referencesInvalid
            guard let writeIndex = queue.jobs.firstIndex(where: { $0.jobID == jobID }) else {
                publishQueuedStatusOntoActiveJobIfNeeded(job)
                bumpStripUI()
                return
            }
            queue.jobs[writeIndex] = job
            applyQueuedJobErrorBanner(at: writeIndex)
            publishQueuedStatusOntoActiveJobIfNeeded(queue.jobs[writeIndex])
            bumpStripUI()
            return
        }

        let hasFluxAI = job.values[JobStepQueue.fluxPromptAIJobKey] as? [String: Any] != nil
        let applyImageExit = !hasFluxAI

        var payload: [String: Any] = [:]
        do {
            payload = try await registry.buildPayload(
                pluginID: job.pluginID,
                values: job.values,
                outputPath: queueStatusPreviewOutputPath(),
                applyImageExit: applyImageExit
            )
        } catch {
            payload = [:]
        }

        if hasFluxAI, !job.fullPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["prompt"] = job.fullPrompt
        }

        if let hf = payload["hf_model_id"] {
            job.values["hf_model_id"] = hf
        }
        if !payload.isEmpty {
            ImageGenLoraWorkerPayloadEnrich.mergeLoraFields(from: payload, into: &job.values)
        }

        let exited = (payload["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !exited.isEmpty, !hasFluxAI {
            job.fullPrompt = exited
        } else {
            job.fullPrompt = JobStepQueue.resolvedFullPrompt(
                stored: job.fullPrompt,
                values: job.values,
                steps: job.steps,
                statusView: job.statusView
            )
        }

        let copiesForStatus = max(1, job.copiesTotal)
        job.values["copies"] = copiesForStatus
        let loraLabel = await resolvedLoraStatusLabel(pluginID: job.pluginID, values: job.values)
        let built = buildQueueStatusView(
            pluginID: job.pluginID,
            function: job.function,
            values: job.values,
            copiesTotal: copiesForStatus,
            payload: payload.isEmpty ? nil : payload,
            withAI: hasFluxAI,
            loraLabel: loraLabel
        )
        job.statusView = built.statusView
        job.thumbnailPaths = cardThumbnailPaths(built.thumbnailPaths)
        job.referencesInvalid = built.referencesInvalid
        guard let writeIndex = queue.jobs.firstIndex(where: { $0.jobID == jobID }) else {
            publishQueuedStatusOntoActiveJobIfNeeded(job)
            bumpStripUI()
            return
        }
        queue.jobs[writeIndex] = job
        applyQueuedJobErrorBanner(at: writeIndex)
        publishQueuedStatusOntoActiveJobIfNeeded(queue.jobs[writeIndex])
        bumpStripUI()
    }

    /// Port of ``_sync_active_job_queue_row`` (active job still has a queue row until the worker pops it).
    private func syncActiveJobQueueRow(
        pluginID: String,
        values: [String: Any],
        copiesTotal: Int
    ) async {
        guard let jobID = activeJobID,
              let index = queue.jobs.firstIndex(where: { $0.jobID == jobID }) else { return }
        queue.jobs[index].pluginID = pluginID
        queue.jobs[index].function = activeFunction
        queue.jobs[index].pluginUnavailable = false
        queue.jobs[index].values = values
        queue.jobs[index].copiesTotal = copiesTotal
        queue.jobs[index].fullPrompt = JobStepQueue.resolvedFullPrompt(
            stored: queue.jobs[index].fullPrompt,
            values: values,
            steps: queue.jobs[index].steps,
            statusView: queue.jobs[index].statusView
        )
        let thumbs = JobCardThumbnailPaths.paths(pluginID: pluginID, values: values)
        if !thumbs.isEmpty {
            queue.jobs[index].thumbnailPaths = thumbs
        }
        queue.jobs[index].referencesInvalid = JobCardThumbnailPaths.referencesInvalid(
            pluginID: pluginID,
            values: values
        )
        await refreshQueuedJobStatus(at: index)
    }

    /// The visible active row reads ``activeStatusView``, not the queued copy.
    private func publishQueuedStatusOntoActiveJobIfNeeded(_ job: ImageGenQueuedJob) {
        guard activeJobID == job.jobID else { return }
        activeStatusView = job.statusView
        let paths = cardThumbnailPaths(job.thumbnailPaths)
        activeThumbnailPaths = paths
        activeJobCardThumbnailPathsCache = paths
    }

    private func applyQueuedJobErrorBanner(at index: Int) {
        guard queue.jobs.indices.contains(index) else { return }
        if queue.jobs[index].inError {
            queue.jobs[index].statusView = QueueJobStatusView.queueStatusViewWithErrorBanner(
                queue.jobs[index].statusView,
                errorMessage: queue.jobs[index].errorMessage
            )
        }
    }

    func refreshActiveJobStatusView() async {
        guard activeJobID != nil else { return }
        let timing = currentTimingForDisplay()
        let loraLabel = await resolvedLoraStatusLabel(pluginID: activePluginID, values: pendingValues)
        let built = buildQueueStatusView(
            pluginID: activePluginID,
            function: activeFunction,
            values: pendingValues,
            copiesTotal: copiesTotal,
            running: isProcessing,
            omitLiveStepsRow: true,
            withAI: jobAIStageActive,
            step: liveStepTotal > 0 ? liveStep : nil,
            stepTotal: liveStepTotal > 0 ? liveStepTotal : nil,
            elapsedSeconds: timing.elapsed,
            estimateSeconds: timing.estimate,
            loraLabel: loraLabel
        )
        activeStatusView = built.statusView
        let cardPaths = cardThumbnailPaths(built.thumbnailPaths)
        activeThumbnailPaths = cardPaths
        activeJobCardThumbnailPathsCache = cardPaths
    }

    private func buildQueueStatusView(
        pluginID: String,
        function: String,
        values: [String: Any],
        copiesTotal: Int,
        payload: [String: Any]? = nil,
        pluginUnavailable: Bool = false,
        running: Bool = false,
        omitLiveStepsRow: Bool = false,
        withAI: Bool = false,
        step: Int? = nil,
        stepTotal: Int? = nil,
        elapsedSeconds: Double? = nil,
        estimateSeconds: Double? = nil,
        loraLabel: String? = nil
    ) -> QueueJobStatusBuildResult {
        QueueJobStatusBuilder.build(
            pluginID: pluginID,
            function: function,
            values: values,
            copiesTotal: copiesTotal,
            payload: payload,
            pluginUnavailable: pluginUnavailable,
            running: running,
            omitLiveStepsRow: omitLiveStepsRow,
            withAI: withAI,
            step: step,
            stepTotal: stepTotal,
            elapsedSeconds: elapsedSeconds,
            estimateSeconds: estimateSeconds,
            loraLabel: loraLabel
        )
    }

    private func resolvedLoraStatusLabel(pluginID: String, values: [String: Any]) async -> String? {
        guard let plugin = ImageGenPluginCatalog.plugin(pluginID: pluginID),
              plugin.loraHostID != nil else { return nil }
        if let bridge = loraBridge, bridge.isAvailable {
            if let text = try? await bridge.exifLabelFromValues(pluginID: pluginID, values: values),
               !text.isEmpty {
                return text
            }
        }
        return ImageGenExifCommentFormatting.loraNameForExifFromValues(
            values: values,
            pipelineID: plugin.pipelineID,
            loraHostID: plugin.loraHostID
        )
    }

    private func resolvedLoraExifLabel(pluginID: String, values: [String: Any]) async -> String? {
        await resolvedLoraStatusLabel(pluginID: pluginID, values: values)
    }

    /// Python ``_copy_cycle_exif_values`` / ``_copy_cycle_exif_plugin``.
    private var copyCycleExifValues: [String: Any] {
        copyCycleValues.isEmpty ? pendingValues : copyCycleValues
    }

    private var copyCycleExifPluginID: String {
        copyCyclePluginID.isEmpty ? activePluginID : copyCyclePluginID
    }

    private func clearCopyCycleExifSnapshot() {
        copyCycleValues = [:]
        copyCyclePluginID = ""
    }

    /// Python ``_cleanup_infill_batch_assets``.
    private func cleanupInfillBatchAssets() {
        guard let plugin = ImageGenPluginCatalog.plugin(pluginID: activePluginID),
              plugin.pipelineID == "mflux_fill_infill" else { return }
        InfillExportService.removePersistedBatch(values: pendingValues)
    }

    private func removeAspectPadTemps() {
        guard !aspectPadTempPaths.isEmpty else { return }
        for path in aspectPadTempPaths where !path.isEmpty {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        aspectPadTempPaths = []
    }

    private func exifFallbackSourcePaths(from values: [String: Any]) -> [String] {
        if let canonical = values["_canonical_source_image_paths"] as? [String], !canonical.isEmpty {
            return canonical.filter { FileManager.default.isReadableFile(atPath: $0) }
        }
        if let sources = values["source_image_paths"] as? [String], !sources.isEmpty {
            return sources.filter { FileManager.default.isReadableFile(atPath: $0) }
        }
        return activeThumbnailPaths.filter { FileManager.default.isReadableFile(atPath: $0) }
    }

    private func removePartialOutput(at outputPath: String) {
        guard !outputPath.isEmpty else { return }
        ProwserTempFiles.cleanupCancelledGenerationOutputArtifacts(outputPath: outputPath)
    }

    private func repairCancelledOutputExifReferences(outputPath: String) async {
        guard !outputPath.isEmpty,
              FileManager.default.fileExists(atPath: outputPath),
              !copyCycleExifPluginID.isEmpty else { return }
        let values = copyCycleExifValues
        let fallback = exifFallbackSourcePaths(from: values)
        _ = try? await ImageGenGenerationExifService.repairCancelledOutputExifReferences(
            pluginID: copyCycleExifPluginID,
            outputPath: outputPath,
            values: values,
            fallbackSourcePaths: fallback,
            tempRoot: config.temporaryFilesDirectory.path
        )
    }

    /// Port of Python progressive preview EXIF before browse refresh.
    func writeProgressivePreviewExifIfNeeded(
        at path: String,
        completedStep: Int? = nil,
        totalSteps: Int? = nil
    ) async {
        guard showProgressiveImages,
              !path.isEmpty,
              FileManager.default.fileExists(atPath: path),
              !copyCycleExifPluginID.isEmpty else { return }
        let step = completedStep ?? liveStep
        let total = totalSteps ?? liveStepTotal
        guard step > 0, total > 0, step < total else { return }
        let values = copyCycleExifValues
        let elapsed = liveGenerationElapsedSeconds()
        let fallback = exifFallbackSourcePaths(from: values)
        _ = try? await ImageGenGenerationExifService.makeReadableUserCommentBeforeBrowse(
            pluginID: copyCycleExifPluginID,
            outputPath: path,
            values: values,
            elapsedSeconds: elapsed,
            completedStep: step,
            totalSteps: total,
            fallbackSourcePaths: fallback,
            tempRoot: config.temporaryFilesDirectory.path
        )
    }

    private func writeGenerationExif(
        outputPath: String,
        pluginID: String,
        values: [String: Any],
        workerResult: [String: Any],
        elapsedSeconds: Double?,
        fallbackSourcePaths: [String]
    ) async {
        guard FileManager.default.fileExists(atPath: outputPath) else { return }
        do {
            try await writeGenerationExifFallback(
                outputPath: outputPath,
                pluginID: pluginID,
                values: values,
                workerResult: workerResult,
                elapsedSeconds: elapsedSeconds,
                fallbackSourcePaths: fallbackSourcePaths
            )
        } catch {
            print("DEBUG writeGenerationExif: failed for \(outputPath): \(error)")
        }
    }

    private func writeGenerationExifFallback(
        outputPath: String,
        pluginID: String,
        values: [String: Any],
        workerResult: [String: Any],
        elapsedSeconds: Double?,
        fallbackSourcePaths: [String] = []
    ) async throws {
        var comment: String
        if !pluginID.isEmpty {
            let loraLabel = await resolvedLoraExifLabel(pluginID: pluginID, values: values)
            let formatted = ImageGenGenerationExifService.formatGenerationExifComment(
                pluginID: pluginID,
                values: values,
                workerResult: workerResult,
                elapsedSeconds: elapsedSeconds,
                lora: loraLabel
            )
            comment = formatted.isEmpty ? (values["prompt"] as? String ?? "") : formatted
        } else if let prompt = values["prompt"] as? String {
            comment = prompt
        } else {
            comment = ""
        }
        let tempRoot = config.temporaryFilesDirectory.path
        comment = ImageGenGenerationExifService.injectReferences(
            baseComment: comment,
            pluginID: pluginID,
            values: values,
            outputPath: outputPath,
            fallbackSourcePaths: fallbackSourcePaths,
            tempRoot: tempRoot
        )
        try await ExifService.writeUserComment(path: outputPath, text: comment)
    }

    private func startLiveStatusTimer() {
        liveStatusTask?.cancel()
        liveStatusTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, self.isProcessing || self.cooldownSecondsRemaining > 0 else { break }
                await self.refreshActiveStripView()
            }
        }
    }

    private func stopLiveStatusTimer() {
        liveStatusTask?.cancel()
        liveStatusTask = nil
    }

    // MARK: - Quit / shutdown

    func isRunning() -> Bool {
        if modelTasks.isBusy || foregroundTasks.isBusy || jobAIStageActive {
            return true
        }
        if copyBatchActive, !copyBatchCancelled {
            return true
        }
        return isProcessing
    }

    func quitInterruptsActiveWorker() -> Bool {
        if modelTasks.isBusy || foregroundTasks.isBusy || jobAIStageActive {
            return true
        }
        // Expand/create prep (``buildPayload`` / placement) runs before ``modelTasks`` is busy.
        if isProcessing, activeJobID != nil {
            return true
        }
        if copyBatchActive, !copyBatchCancelled {
            return true
        }
        return false
    }

    func resetTerminateQuitConfirmation() {
        terminateQuitConfirmed = false
    }

    func hasPendingWork() -> Bool {
        !queue.jobs.isEmpty || isRunning() || activeJobID != nil
    }

    /// Return true when terminate may proceed without showing a dialog.
    func quitGateAllowsImmediateTerminate() -> Bool {
        if terminateQuitConfirmed {
            return true
        }
        if quitAfterCurrentWorker {
            if quitInterruptsActiveWorker() {
                return false
            }
            if deferredQuitWaitAllJobs, !deferredQuitPipelineIdle() {
                return false
            }
            return true
        }
        return !quitInterruptsActiveWorker()
    }

    func prepareForShutdown() {
        terminateQuitConfirmed = true
        quitAfterCurrentWorker = false
        deferredQuitWaitAllJobs = false
        dismissDeferredQuitDialog()
        suppressTaskFailureUI = true
        queueAdvanceSuppressed = true
        persistJobQueueForExit()
        abortActiveGenerationForShutdown()
        if foregroundTasks.isBusy {
            foregroundTasks.cancel()
        }
    }

    func cleanup() {
        dismissDeferredQuitDialog()
        quitAfterCurrentWorker = false
        deferredQuitWaitAllJobs = false
        startupQueueHold = false
        startupQueueReleaseToken += 1
        queueAdvanceSuppressed = true
        suppressTaskFailureUI = true
        persistJobQueueForExit()
        copyBatchCancelled = true
        cooldownTask?.cancel()
        cooldownDisplayTask?.cancel()
        cooldownSecondsRemaining = 0
        queue.jobs.removeAll()
        activeJobID = nil
        clearActiveGenerationState()
        bumpQueueRevision()
    }

    func deferredQuitStatusMessage() -> String {
        if deferredQuitWaitAllJobs {
            return "Prowser will shut down after all queued jobs finish."
        }
        if copyBatchActive {
            return "Prowser will shut down after the current copy completes.\nExisting jobs will be requeued on the next startup."
        }
        return "Prowser will shut down after the current task completes."
    }

    func deferredQuitToggleButtonLabel() -> String {
        deferredQuitWaitAllJobs ? "Quit after current copy" : "Wait for all"
    }

    func deferredQuitShowWaitForAllOption() -> Bool {
        deferredQuitHasMoreWorkAfterCurrent() && !deferredQuitWorkIncludesContinuous()
    }

    func toggleDeferredQuitMode() {
        if deferredQuitWaitAllJobs {
            setDeferredQuitAfterCurrentCopy()
        } else {
            setDeferredQuitWaitAllJobs()
        }
        if windowForDeferredQuit {
            deferredQuitDialog.refresh(imageGen: self)
        }
    }

    func cancelDeferredQuit() {
        quitAfterCurrentWorker = false
        deferredQuitWaitAllJobs = false
        queueAdvanceSuppressed = false
        dismissDeferredQuitDialog()
    }

    func beginQuitAfterCurrentWorker() {
        quitAfterCurrentWorker = true
        deferredQuitWaitAllJobs = false
        queueAdvanceSuppressed = true
        persistJobQueueForExit()
        Task { @MainActor in
            tryCompleteDeferredQuitAfterCurrentCopy()
        }
    }

    private func setDeferredQuitWaitAllJobs() {
        deferredQuitWaitAllJobs = true
        queueAdvanceSuppressed = false
        exitQueuePersisted = false
        queuePersistSuppressed = false
        resumeDeferredQuitQueueAdvance()
    }

    private func setDeferredQuitAfterCurrentCopy() {
        deferredQuitWaitAllJobs = false
        queueAdvanceSuppressed = true
        persistJobQueueForExit()
        tryCompleteDeferredQuitAfterCurrentCopy()
    }

    private weak var deferredQuitAppState: AppState?

    func setDeferredQuitAppState(_ appState: AppState) {
        deferredQuitAppState = appState
    }

    private func tryCompleteDeferredQuitAfterCurrentCopy() {
        guard quitAfterCurrentWorker else { return }
        if deferredQuitWaitAllJobs { return }
        if jobAIStageActive || modelTasks.isBusy || foregroundTasks.isBusy || cooldownSecondsRemaining > 0 {
            if let appState = deferredQuitAppState {
                if !windowForDeferredQuit {
                    deferredQuitDialog.show(imageGen: self, appState: appState)
                    windowForDeferredQuit = true
                } else {
                    deferredQuitDialog.refresh(imageGen: self)
                }
            }
            return
        }
        if copyBatchActive {
            finishCopyBatch(cancelled: false)
        }
        maybeQuitAfterCurrentWorker()
    }

    private var windowForDeferredQuit = false

    private func maybeQuitAfterCurrentWorker() {
        guard quitAfterCurrentWorker else { return }
        if jobAIStageActive { return }
        if modelTasks.isBusy || foregroundTasks.isBusy {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
                maybeQuitAfterCurrentWorker()
            }
            return
        }
        if deferredQuitWaitAllJobs, !deferredQuitPipelineIdle() {
            return
        }
        quitAfterCurrentWorker = false
        deferredQuitWaitAllJobs = false
        dismissDeferredQuitDialog()
        onDeferredQuitComplete?()
    }

    private func deferredQuitPipelineIdle() -> Bool {
        if jobAIStageActive { return false }
        if modelTasks.isBusy || foregroundTasks.isBusy { return false }
        return !hasPendingWork()
    }

    private func deferredQuitHasMoreWorkAfterCurrent() -> Bool {
        if !queue.jobs.isEmpty { return true }
        return pendingBatchCopies() > 1
    }

    private func deferredQuitWorkIncludesContinuous() -> Bool {
        if JobStepQueue.pendingDocIsContinuous(stepPendingDoc, runningStep: stepRunning) {
            return true
        }
        if copyBatchActive, JobStepQueue.isSeriesContinuousCopies(copiesTotal) {
            return true
        }
        return queue.jobs.contains { JobStepQueue.isSeriesContinuousCopies($0.copiesTotal) }
    }

    private func pendingBatchCopies() -> Int {
        JobStepQueue.pendingStepCount(stepPendingDoc) + (stepRunning != nil ? 1 : 0)
    }

    @discardableResult
    private func finishCurrentUnitAndMaybeQuit() -> Bool {
        guard quitAfterCurrentWorker, !deferredQuitWaitAllJobs else { return false }
        syncChainStateToPendingDoc()
        let remaining = JobStepQueue.pendingStepCount(stepPendingDoc)
        if remaining > 0 {
            JobStepPersistence.saveActivePending(stepPendingDoc, config: config)
            JobStepPersistence.saveActiveRunning(nil, config: config)
        } else {
            JobStepPersistence.saveActivePending(nil, config: config)
            JobStepPersistence.saveActiveRunning(nil, config: config)
        }
        finishCopyBatch(cancelled: false)
        return true
    }

    private func dismissDeferredQuitDialog() {
        windowForDeferredQuit = false
        deferredQuitDialog.dismiss()
        deferredQuitAppState = nil
    }

    private func prependRunningStepToPending() {
        guard let running = stepRunning else { return }
        var doc = stepPendingDoc
        if doc == nil, let activeJobID {
            doc = JobStepQueue.buildPendingJobDoc(
                jobID: activeJobID,
                pluginID: activePluginID,
                function: activeFunction,
                steps: [],
                fullPrompt: pendingValues["prompt"] as? String ?? "",
                thumbnailPaths: activeThumbnailPaths,
                stepsDone: copiesDone
            )
        }
        guard var doc else { return }
        syncChainStateToPendingDoc()
        doc = stepPendingDoc ?? doc
        stepPendingDoc = JobStepQueue.prependPendingStep(doc: doc, step: running)
        stepRunning = nil
        JobStepPersistence.saveActiveRunning(nil, config: config)
    }

    private func persistJobQueueForExit() {
        if exitQueuePersisted { return }
        if stepRunning != nil, !quitAfterCurrentWorker {
            prependRunningStepToPending()
        }
        syncChainStateToPendingDoc()
        let runningDoc: [String: Any]?
        if let stepRunning {
            runningDoc = JobStepQueue.buildRunningJobDoc(
                jobID: activeJobID ?? "",
                pluginID: activePluginID,
                function: activeFunction,
                step: stepRunning,
                outputPath: activeOutputPath ?? "",
                fullPrompt: pendingValues["prompt"] as? String ?? "",
                thumbnailPaths: activeThumbnailPaths
            )
        } else {
            runningDoc = nil
        }
        JobStepPersistence.persistStepJobFiles(
            running: runningDoc,
            pending: stepPendingDoc,
            queue: queueWithActiveDisplayIndex(),
            config: config
        )
        exitQueuePersisted = true
        queuePersistSuppressed = true
    }

    private func queueWithActiveDisplayIndex() -> ImageGenQueueFile {
        var file = queue
        file.activeDisplayIndex = activeDisplayIndex
        return file
    }

    private func syncChainStateToPendingDoc() {
        guard stepPendingDoc != nil else { return }
        stepPendingDoc = JobStepQueue.syncChainStateToPendingDoc(
            stepPendingDoc,
            outputPath: activeOutputPath ?? "",
            prompt: pendingValues["prompt"] as? String ?? "",
            priorValues: pendingValues
        )
    }

    /// Port of ``ImageGenController._complete_running_step_after_copy``.
    private func completeRunningStepAfterCopy() {
        stepRunning = nil
        JobStepPersistence.saveActiveRunning(nil, config: config)
        if var doc = stepPendingDoc {
            let done = (doc["steps_done"] as? Int) ?? 0
            doc["steps_done"] = done + 1
            stepPendingDoc = doc
        }
        syncCopiesDoneDisplay()
        syncChainStateToPendingDoc()
        persistStepState()
    }

    /// Port of ``ImageGenController._sync_copies_done_display``.
    private func syncCopiesDoneDisplay() {
        if JobStepQueue.isSeriesContinuousCopies(copiesTotal) {
            copiesDone = 0
        } else if let doc = stepPendingDoc {
            copiesDone = max(0, doc["steps_done"] as? Int ?? 0)
        }
    }

    private func intFromAny(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    /// Non-empty preview path from worker progress (file may not be visible yet; AppState retries on flush).
    private func progressMessagePath(from message: [String: Any]) -> String? {
        let keys = ["path", "preview_path", "progressive_output_path"]
        for key in keys {
            guard let raw = message[key] as? String else { continue }
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { continue }
            return path
        }
        return nil
    }

    private func abortActiveGenerationForShutdown() {
        if !isRunning(), !isProcessing {
            clearActiveGenerationState()
            return
        }
        copyBatchCancelled = true
        if stepRunning != nil {
            prependRunningStepToPending()
        }
        cooldownTask?.cancel()
        cooldownDisplayTask?.cancel()
        cooldownSecondsRemaining = 0
        if jobAIStageActive {
            foregroundTasks.cancel()
            jobAIStageActive = false
        }
        modelTasks.shutdown()
        clearActiveGenerationState()
    }

    private func clearActiveGenerationState() {
        activeJobID = nil
        isProcessing = false
        progressMessage = ""
        taskStatusHTML = ""
        stopLiveStatusTimer()
        activeStatusView = nil
        activeStripView = ActiveJobStripStatusView()
        resetActiveJobProgressTracking()
        generationStartTime = nil
        skipSeriesCopyInFlight = false
        progressivePreviewPath = nil
        activeOutputPath = nil
        activeThumbnailPaths = []
        activeJobCardThumbnailPathsCache = []
        stepRunning = nil
        stepPendingDoc = nil
        jobAIStageActive = false
        copyBatchActive = false
        copiesTotal = 0
        copiesDone = 0
        if !queuePersistSuppressed {
            JobStepPersistence.saveActiveRunning(nil, config: config)
            JobStepPersistence.saveActivePending(nil, config: config)
        }
    }

    private func restorePersistedJobQueue() {
        queue = JobStepPersistence.loadQueue(config: config)
        ImageGenJobNumber.reconcile(
            knownNumbers: queue.jobs.compactMap(\.jobNumber),
            config: config
        )
        activeDisplayIndex = queue.activeDisplayIndex
        let hasActive = restoreActiveJobFromStepFiles()
        Task { await refreshAllQueuedJobStatusViews() }
        if (!queue.jobs.isEmpty || hasActive), !holdJobQueue {
            startupQueueHold = true
        }
        bumpQueueRevision()
    }

    @discardableResult
    private func restoreActiveJobFromStepFiles() -> Bool {
        let runningDoc = JobStepPersistence.loadActiveRunning(config: config)
        let pendingDoc = JobStepPersistence.loadActivePending(config: config)
        guard runningDoc != nil || pendingDoc != nil else { return false }
        let source = runningDoc ?? pendingDoc
        guard let source else { return false }
        let pluginID = source["plugin_id"] as? String ?? ""
        let function = source["function"] as? String ?? ""
        let jobID = source["job_id"] as? String ?? ""
        guard !pluginID.isEmpty, !function.isEmpty, !jobID.isEmpty else { return false }

        activeJobID = jobID
        activeDisplayIndex = max(0, min(activeDisplayIndex, queue.jobs.count))
        activePluginID = pluginID
        activeFunction = function
        stepPendingDoc = pendingDoc
        copiesDone = 0
        if let pendingDoc {
            if let display = pendingDoc["display"] as? [String: Any],
               let thumbs = display["thumbnail_paths"] as? [String] {
                activeThumbnailPaths = thumbs.filter { FileManager.default.fileExists(atPath: $0) }
            }
            syncCopiesDoneDisplay()
        }
        if activeThumbnailPaths.isEmpty,
           let steps = pendingDoc?["steps"] as? [[String: Any]],
           let first = steps.first {
            pendingValues = JobStepQueue.mergeStepIntoValues(first)
        }
        if let runningDoc, let step = runningDoc["step"] as? [String: Any] {
            stepRunning = step
            pendingValues = JobStepQueue.mergeStepIntoValues(step)
        } else if let pendingDoc,
                  let steps = pendingDoc["steps"] as? [[String: Any]],
                  let first = steps.first {
            var values = JobStepQueue.mergeStepIntoValues(first)
            let pendingCount = steps.count
            values["copies"] = max(1, copiesDone + pendingCount)
            pendingValues = values
        }
        let pendingCount = JobStepQueue.pendingStepCount(stepPendingDoc)
        let runningCount = stepRunning != nil ? 1 : 0
        if JobStepQueue.pendingDocIsContinuous(stepPendingDoc, runningStep: stepRunning) {
            copiesTotal = JobStepQueue.seriesContinuousCopies
            pendingValues["copies"] = JobStepQueue.seriesContinuousCopies
            copyBatchActive = true
        } else {
            let copies = pendingValues["copies"] as? Int ?? Int("\(pendingValues["copies"] ?? "")") ?? 0
            if JobStepQueue.isSeriesContinuousCopies(copies) {
                copiesTotal = JobStepQueue.seriesContinuousCopies
                pendingValues["copies"] = JobStepQueue.seriesContinuousCopies
            } else {
                copiesTotal = max(1, copiesDone + pendingCount + runningCount)
            }
            copyBatchActive = copiesTotal > 1 || copiesDone > 0
        }
        copyBatchCancelled = false
        return true
    }

    private func releaseStartupQueueHold() {
        guard startupQueueHold else { return }
        startupQueueHold = false
        guard !holdJobQueue else { return }
        if activeJobID != nil, !modelTasks.isBusy {
            resumeRestoredActiveJobIfIdle()
            return
        }
        processNextIfIdle()
    }

    private func resumeRestoredActiveJobIfIdle() {
        guard !holdJobQueue, !startupQueueHold else { return }
        guard activeJobID != nil, !modelTasks.isBusy else {
            processNextIfIdle()
            return
        }
        if let step = stepRunning {
            let displayPrompt = (stepPendingDoc?["display"] as? [String: Any])?["full_prompt"] as? String ?? ""
            let statusViewPrompt = JobStepQueue.promptFromStatusView(activeStatusView)
            let values = JobStepQueue.generationValues(
                from: step,
                jobValues: pendingValues,
                displayFullPrompt: displayPrompt,
                statusViewPrompt: statusViewPrompt
            )
            pendingValues = values
            isProcessing = true
            generationStartTime = Date()
            startLiveStatusTimer()
            rebuildActiveStripViewLocally()
            bumpQueueRevision()
            if JobStepQueue.stepNeedsAI(step) {
                Task { await runJobAIStage(values: values) }
            } else {
                Task { await launchGeneration(values: values) }
            }
            return
        }
        Task { await promoteAndRunNextStep() }
    }

    private func resumeAfterHoldReleased() {
        if queueAdvanceSuppressed { return }
        if let activeJobID, queuedJob(byID: activeJobID) == nil, activeBatchHasRemainingWork() {
            _ = demoteActiveRemainingToQueue()
        }
        if !modelTasks.isBusy {
            processNextIfIdle()
        }
    }

    private func activeBatchHasRemainingWork() -> Bool {
        if copyBatchCancelled { return false }
        if JobStepQueue.isSeriesContinuousCopies(copiesTotal) { return true }
        if JobStepQueue.pendingDocIsContinuous(stepPendingDoc, runningStep: stepRunning) { return true }
        return pendingBatchCopies() > 0
    }

    private func resumeDeferredQuitQueueAdvance() {
        guard quitAfterCurrentWorker, deferredQuitWaitAllJobs else { return }
        if holdJobQueue { return }
        if copyBatchActive, !copyBatchCancelled, pendingBatchCopies() > 0, !modelTasks.isBusy, cooldownSecondsRemaining == 0 {
            Task { await promoteAndRunNextStep() }
            return
        }
        if !isRunning() {
            processNextIfIdle()
        }
    }

    func refreshActiveStripView(includeQueueJobsRow: Bool = false, force: Bool = false) async {
        guard isEnabled, isProcessing || cooldownSecondsRemaining > 0 else {
            activeStripView = ActiveJobStripStatusView()
            lastCooldownUISecond = nil
            publishActiveStrip(preferLiveFields: true)
            return
        }
        if !force, !stripDisplayNeedsRefresh() {
            return
        }
        rebuildActiveStripViewLocally(includeQueueJobsRow: includeQueueJobsRow)
        markStripDisplayRefreshed()
        publishActiveStrip(preferLiveFields: true)
    }
}

enum ImageGenError: LocalizedError {
    case emptyPrompt
    case unavailable
    case pipelineFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyPrompt: return "Prompt is required."
        case .unavailable: return "Image generation is not available."
        case .pipelineFailed(let message): return message
        }
    }
}
