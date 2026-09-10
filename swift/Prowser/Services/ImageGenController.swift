import Foundation

/// Swift port of `imagegen_plugins/image_gen_controller.py`.
@Observable
@MainActor
final class ImageGenController {
    private let config: AppConfig
    private let modelTasks: ModelTasksBridge
    private let foregroundTasks: ModelTasksBridge
    private let registry: ImageGenRegistryBridge

    private(set) var queue: ImageGenQueueFile = ImageGenQueueFile()
    private(set) var activeJobID: String?
    private(set) var isProcessing = false
    private(set) var lastError = ""
    private(set) var progressMessage = ""
    private(set) var taskStatusHTML = ""
    private(set) var progressivePreviewPath: String?
    private(set) var showProgressiveImages = false
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
    private var liveStep = 0
    private var liveStepTotal = 0
    private var liveEstimateSeconds: Double?
    private var statusRefreshTask: Task<Void, Never>?
    private var copiesTotal = 0
    private var copiesDone = 0
    private var copyBatchActive = false
    private var activeDisplayIndex = 0
    private var activeThumbnailPaths: [String] = []
    private var activePluginID = ""
    private var activeFunction = "create"
    private var pendingValues: [String: Any] = [:]
    private var stepRunning: [String: Any]?
    private var stepPendingDoc: [String: Any]?
    private var jobAIStageActive = false
    private var cooldownTask: Task<Void, Never>?
    private var cooldownDisplayTask: Task<Void, Never>?
    private var liveStatusTask: Task<Void, Never>?
    private var activeStatusView: QueueJobStatusView?
    private var quitAfterCurrentWorker = false
    private var deferredQuitWaitAllJobs = false
    private var queueAdvanceSuppressed = false
    private var exitQueuePersisted = false
    private var queuePersistSuppressed = false
    private var startupQueueHold = false
    private var startupQueueReleaseTask: Task<Void, Never>?
    private var copyBatchCancelled = false
    private var suppressTaskFailureUI = false
    private let deferredQuitDialog = DeferredQuitDialog()

    var onDeferredQuitComplete: (() -> Void)?

    var isEnabled: Bool { BundleCapabilities.imageGenUIEnabled && modelTasks.isAvailable && registry.isAvailable }

    var canSkipActiveSeriesCopy: Bool {
        isProcessing && !skipSeriesCopyRequested && copyBatchActive
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

    var isDialogBuildPaused: Bool { dialogBuildPauseCount > 0 }

    var onImageGenerated: ((String) -> Void)?
    /// Called when a progressive step preview is written to disk (debounced by AppState).
    var onProgressivePreview: ((String) -> Void)?
    var onQueueChanged: (() -> Void)?

    init(
        config: AppConfig,
        modelTasks: ModelTasksBridge,
        foregroundTasks: ModelTasksBridge,
        registry: ImageGenRegistryBridge
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

    func scheduleStartupQueueRelease(delayMs: Int = 6_000) {
        guard startupQueueHold, !holdJobQueue else { return }
        startupQueueReleaseTask?.cancel()
        startupQueueReleaseTask = Task {
            let delay = max(0, delayMs)
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
            }
            guard !Task.isCancelled else { return }
            releaseStartupQueueHold()
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
        showProgressiveImages = imagegen["show_progressive_images"] as? Bool ?? false
        let newHold = imagegen["hold_job_queue"] as? Bool ?? false
        if newHold {
            startupQueueReleaseTask?.cancel()
            startupQueueHold = false
        }
        holdJobQueue = newHold
    }

    func setShowProgressiveImages(_ enabled: Bool) {
        guard showProgressiveImages != enabled else { return }
        showProgressiveImages = enabled
        mutateImagegen { $0["show_progressive_images"] = enabled }
    }

    func setHoldJobQueue(_ enabled: Bool) {
        guard holdJobQueue != enabled else { return }
        holdJobQueue = enabled
        mutateImagegen { $0["hold_job_queue"] = enabled }
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
        if modelTasks.isBusy {
            modelTasks.cancel()
        }
    }

    func skipCopyCooldown() {
        cooldownTask?.cancel()
        cooldownSecondsRemaining = 0
        bumpQueueRevision()
        Task { await promoteAndRunNextStep() }
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
        submitValues = try await registry.normalizeValues(pluginID: pluginID, values: submitValues, mode: "snapshot")
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
        if isEnabled {
            do {
                let built = try await registry.buildQueueStatusView(
                    pluginID: pluginID,
                    function: function,
                    values: submitValues,
                    copiesTotal: normalizedCopies
                )
                job.statusView = built.statusView
                job.thumbnailPaths = cardThumbnailPaths(built.thumbnailPaths)
                job.fullPrompt = built.fullPrompt
                job.referencesInvalid = built.referencesInvalid
            } catch {
                job.statusView = QueueJobStatusView.degradedFallback(
                    prompt: prompt,
                    copiesTotal: normalizedCopies
                )
            }
        } else {
            job.statusView = QueueJobStatusView.degradedFallback(
                prompt: prompt,
                copiesTotal: normalizedCopies
            )
        }
        queue.jobs.append(job)
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
        var rows = queue.jobs
            .filter { $0.jobID != activeJobID }
            .map { job in
                QueueRowSnapshot(
                    jobID: job.jobID,
                    isActive: false,
                    statusHTML: job.statusHTML,
                    statusView: job.statusView,
                    thumbnailPaths: cardThumbnailPaths(job.thumbnailPaths),
                    fullPrompt: job.fullPrompt,
                    referencesInvalid: job.referencesInvalid,
                    pluginUnavailable: job.pluginUnavailable,
                    statusLabel: job.statusLabel,
                    copiesTotal: job.copiesTotal
                )
            }
        if let activeJobID {
            let insertAt = max(0, min(activeDisplayIndex, rows.count))
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
                copiesTotal: copiesTotal
            )
            rows.insert(activeRow, at: insertAt)
        }
        return rows
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
        submitValues = try await registry.normalizeValues(pluginID: pluginID, values: submitValues, mode: "snapshot")
        let steps = try await registry.materializeSteps(pluginID: pluginID, values: submitValues, copies: copies)
        queue.jobs[index].pluginID = pluginID
        queue.jobs[index].function = function
        queue.jobs[index].values = submitValues
        queue.jobs[index].copiesTotal = copies
        queue.jobs[index].steps = steps
        queue.jobs[index].fullPrompt = submitValues["prompt"] as? String ?? ""
        queue.jobs[index].statusHTML = "Queued"
        await refreshQueuedJobStatus(at: index)
        persistQueue()
        bumpQueueRevision()
    }

    func updateActiveJobRemaining(jobID: String, pluginID: String, values: [String: Any]) async throws {
        guard jobID == activeJobID else { return }
        let inProgress = isProcessing ? 1 : 0
        var remaining = JobStepQueue.normalizeCopies(values["copies"] ?? 1)
        if inProgress > 0 { remaining = max(1, remaining) }
        let copies = copiesDone + remaining
        var submitValues = values
        submitValues["copies"] = copies
        submitValues = try await registry.normalizeValues(pluginID: pluginID, values: submitValues, mode: "snapshot")
        copiesTotal = copies
        copyBatchActive = copies > 1 || copiesDone > 0
        activePluginID = pluginID
        pendingValues = submitValues
        let future = max(0, copies - copiesDone - inProgress)
        if var doc = stepPendingDoc {
            let steps = try await registry.materializeSteps(pluginID: pluginID, values: submitValues, copies: future)
            doc["steps"] = steps
            stepPendingDoc = doc
        }
        persistStepState()
        bumpQueueRevision()
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
            persistQueue()
            bumpQueueRevision()
            return
        }
        queue.jobs.removeAll { $0.jobID == id }
        persistQueue()
        bumpQueueRevision()
    }

    func cancelActiveJob() {
        modelTasks.cancel()
        copyBatchActive = false
        if let activeJobID,
           let index = queue.jobs.firstIndex(where: { $0.jobID == activeJobID }) {
            queue.jobs[index].statusHTML = "Cancelled"
        }
        finishActiveJob(cancelled: true)
    }

    func removeJob(id: String) {
        cancelJob(id: id)
    }

    // MARK: - Series controls

    func addActiveSeriesCycle(delta: Int = 1) {
        guard activeJobID != nil else { return }
        if JobStepQueue.isSeriesContinuousCopies(copiesTotal) { return }
        copiesTotal = min(50, copiesTotal + delta)
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
        if var doc = stepPendingDoc {
            doc[JobStepQueue.continuousModeKey] = true
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
        persistQueue()
        bumpQueueRevision()
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
            let inProgress = isProcessing ? 1 : 0
            return max(0, copiesTotal - copiesDone - inProgress)
        }
        guard let job = queue.jobs.first(where: { $0.jobID == jobID }) else { return 0 }
        return max(1, job.copiesTotal)
    }

    private func canAddSeriesCycle(for jobID: String) -> Bool {
        guard jobID == activeJobID else { return false }
        guard !JobStepQueue.isSeriesContinuousCopies(copiesTotal) else { return false }
        return copiesTotal < 50
    }

    private func canSubtractSeriesCycle(for jobID: String) -> Bool {
        guard jobID == activeJobID else { return false }
        return seriesRemainingAfter(for: jobID) > 0
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
            let held = rows.count
            if held > 0 { return "=\(held) " }
            return ""
        }
        let waiting = rows.filter { !$0.isActive }.count
        if waiting > 0 { return "+\(waiting) " }
        return ""
    }

    // MARK: - Internal processing

    private func startNextQueuedJobIfIdle() async {
        guard isEnabled, !modelTasks.isBusy, activeJobID == nil, !holdJobQueue, !startupQueueHold, !queueAdvanceSuppressed else { return }
        guard let index = queue.jobs.firstIndex(where: { $0.statusHTML == "Queued" || $0.statusLabel == "Queued" }) else {
            return
        }
        var job = queue.jobs[index]
        queue.jobs.remove(at: index)
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
            }
        }
        activeJobID = job.jobID
        activePluginID = job.pluginID
        activeFunction = job.function
        pendingValues = job.values
        copiesTotal = job.copiesTotal
        copiesDone = 0
        copyBatchActive = job.copiesTotal > 1
        activeThumbnailPaths = job.thumbnailPaths
        activeStatusView = job.statusView
        activeDisplayIndex = index
        stepPendingDoc = JobStepQueue.buildPendingJobDoc(
            jobID: job.jobID,
            pluginID: job.pluginID,
            function: job.function,
            steps: steps,
            fullPrompt: resolvedPrompt,
            thumbnailPaths: job.thumbnailPaths
        )
        persistQueue()
        await promoteAndRunNextStep()
    }

    private func promoteAndRunNextStep() async {
        guard var doc = stepPendingDoc else {
            finishActiveJob(cancelled: false)
            return
        }
        guard let step = JobStepQueue.popNextStep(from: &doc) else {
            stepPendingDoc = doc
            finishActiveJob(cancelled: false)
            return
        }
        stepPendingDoc = doc
        stepRunning = step
        copiesDone = (doc["steps_done"] as? Int) ?? copiesDone
        isProcessing = true
        generationStartTime = Date()
        liveStep = 0
        liveStepTotal = 0
        liveEstimateSeconds = nil
        progressMessage = "Starting…"
        taskStatusHTML = progressMessage
        startLiveStatusTimer()
        await refreshActiveJobStatusView()
        bumpQueueRevision()

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
            await runJobAIStage(values: values)
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
            handleStepFailure(error.localizedDescription)
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
        let outputPath = ImageGenPathNaming.nextImageGenPath(config: config, ext: ".png")
        activeOutputPath = outputPath
        do {
            let payload = try await registry.buildPayload(
                pluginID: activePluginID,
                values: values,
                outputPath: outputPath
            )
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
            generationStartTime = Date()
            await refreshActiveJobStatusView()
            await refreshActiveStripView()
            _ = try modelTasks.startGenerate(payload: payload)
            bumpQueueRevision()
        } catch {
            handleStepFailure(error.localizedDescription)
        }
    }

    private func handleGenerateFinished(success: Bool, outputPath: String, error: String) {
        defer {
            skipSeriesCopyRequested = false
            skipSeriesCopyInFlight = false
        }
        if skipSeriesCopyRequested {
            _ = outputPath
            stepRunning = nil
            if seriesContinues() {
                Task { await promoteAndRunNextStep() }
            } else {
                finishActiveJob(cancelled: false)
            }
            return
        }

        if success, !outputPath.isEmpty {
            let exifPluginID = activePluginID
            let exifValues = pendingValues
            let workerResult = modelTasks.lastGenerateResult
            let exifElapsed = elapsedSeconds()
            let fallbackSourcePaths = exifFallbackSourcePaths(from: exifValues)
            Task {
                await writeGenerationExif(
                    outputPath: outputPath,
                    pluginID: exifPluginID,
                    values: exifValues,
                    workerResult: workerResult,
                    elapsedSeconds: exifElapsed,
                    fallbackSourcePaths: fallbackSourcePaths
                )
            }
            onImageGenerated?(outputPath)
            lastError = ""
            progressMessage = "Done"
        } else {
            lastError = error
            if error == "Cancelled" {
                if suppressTaskFailureUI || queuePersistSuppressed {
                    return
                }
                finishActiveJob(cancelled: true)
                return
            }
        }

        stepRunning = nil
        if finishCurrentUnitAndMaybeQuit() {
            return
        }
        if seriesContinues() {
            scheduleCooldownThen { await self.promoteAndRunNextStep() }
        } else {
            finishActiveJob(cancelled: false)
        }
    }

    private func seriesContinues() -> Bool {
        guard copyBatchActive else { return false }
        if JobStepQueue.isSeriesContinuousCopies(copiesTotal) { return true }
        return JobStepQueue.pendingStepCount(stepPendingDoc) > 0
    }

    private func finishActiveJob(cancelled: Bool) {
        activeJobID = nil
        isProcessing = false
        progressMessage = ""
        taskStatusHTML = ""
        stopLiveStatusTimer()
        activeStatusView = nil
        activeStripView = ActiveJobStripStatusView()
        generationStartTime = nil
        liveStep = 0
        liveStepTotal = 0
        liveEstimateSeconds = nil
        skipSeriesCopyInFlight = false
        progressivePreviewPath = nil
        activeOutputPath = nil
        activeThumbnailPaths = []
        stepRunning = nil
        stepPendingDoc = nil
        copyBatchActive = false
        copiesTotal = 0
        copiesDone = 0
        jobAIStageActive = false
        if !queuePersistSuppressed {
            JobStepPersistence.saveActiveRunning(nil, config: config)
            JobStepPersistence.saveActivePending(nil, config: config)
            persistQueue()
        }
        bumpQueueRevision()
        if !holdJobQueue, !queueAdvanceSuppressed, !startupQueueHold {
            Task { await startNextQueuedJobIfIdle() }
        }
        maybeQuitAfterCurrentWorker()
    }

    private func handleStepFailure(_ message: String) {
        if suppressTaskFailureUI || queuePersistSuppressed { return }
        lastError = message
        progressMessage = "Failed"
        taskStatusHTML = progressMessage
        finishActiveJob(cancelled: true)
    }

    private func processNextIfIdle() {
        Task { await startNextQueuedJobIfIdle() }
    }

    private func scheduleCooldownThen(_ action: @escaping () async -> Void) {
        cooldownTask?.cancel()
        cooldownDisplayTask?.cancel()
        let ms = config.imageGenInt("job_cooldown_ms", default: 0)
        let seconds = max(0, ms / 1000)
        cooldownSecondsRemaining = seconds
        Task { await refreshActiveStripView() }
        bumpQueueRevision()
        cooldownDisplayTask = Task {
            while cooldownSecondsRemaining > 0, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                cooldownSecondsRemaining = max(0, cooldownSecondsRemaining - 1)
                await refreshActiveStripView()
                bumpQueueRevision()
            }
        }
        cooldownTask = Task {
            if ms > 0 {
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            }
            guard !Task.isCancelled else { return }
            cooldownSecondsRemaining = 0
            if quitAfterCurrentWorker, !deferredQuitWaitAllJobs {
                finishCopyBatchForDeferredQuit()
                maybeQuitAfterCurrentWorker()
                return
            }
            await action()
        }
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
            steps: stepPendingDoc?["steps"] as? [[String: Any]] ?? []
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
        guard dialogBuildPauseCount == 0 else { return }
        queueRevision += 1
        onQueueChanged?()
    }

    private func wireBridgeCallbacks() {
        modelTasks.onJobProcessingStarted = { [weak self] kind in
            guard let self else { return }
            if kind == "generate" {
                self.progressMessage = "Generating…"
                self.taskStatusHTML = self.progressMessage
                self.bumpQueueRevision()
            }
        }
        modelTasks.onProgress = { [weak self] message in
            guard let self else { return }
            if let path = message["progressive_output_path"] as? String
                ?? message["preview_path"] as? String
                ?? message["path"] as? String {
                self.progressivePreviewPath = path
                let step = (message["step"] as? Int) ?? Int("\(message["step"] ?? "")") ?? -1
                if self.showProgressiveImages, step != 0 {
                    self.onProgressivePreview?(path)
                }
            }
            if let step = message["step"] as? Int {
                self.liveStep = step
                self.progressMessage = "Step \(step)"
                self.taskStatusHTML = self.progressMessage
            } else if let step = message["step"] {
                self.liveStep = (step as? Int) ?? Int("\(step)") ?? self.liveStep
                self.progressMessage = "Step \(step)"
                self.taskStatusHTML = self.progressMessage
            }
            if let total = message["step_total"] as? Int {
                self.liveStepTotal = total
            } else if let total = message["total_steps"] as? Int {
                self.liveStepTotal = total
            }
            if let estimate = message["estimate_seconds"] as? Double {
                self.liveEstimateSeconds = estimate
            } else if let estimate = message["estimate_seconds"] as? Int {
                self.liveEstimateSeconds = Double(estimate)
            }
            Task {
                await self.refreshActiveJobStatusView()
                await self.refreshActiveStripView()
                self.bumpQueueRevision()
            }
        }
        modelTasks.onGenerateFinished = { [weak self] success, outputPath, error in
            self?.handleGenerateFinished(success: success, outputPath: outputPath, error: error)
        }
    }

    private func mutateImagegen(_ mutate: (inout [String: Any]) -> Void) {
        var imagegen = config.rawSettings()["imagegen"] as? [String: Any] ?? [:]
        mutate(&imagegen)
        config.updateSetting("imagegen", value: imagegen)
    }

    private func elapsedSeconds() -> Double? {
        guard let generationStartTime else { return nil }
        return Date().timeIntervalSince(generationStartTime)
    }

    /// Port of ``ImageGenController._active_job_card_thumbnail_paths``.
    private func activeJobCardThumbnailPaths() -> [String] {
        cardThumbnailPaths(activeThumbnailPaths)
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
        guard isEnabled else { return }
        for index in queue.jobs.indices {
            await refreshQueuedJobStatus(at: index)
        }
        persistQueue()
        bumpQueueRevision()
    }

    private func refreshQueuedJobStatus(at index: Int) async {
        guard queue.jobs.indices.contains(index) else { return }
        let job = queue.jobs[index]
        guard isEnabled else {
            queue.jobs[index].statusView = QueueJobStatusView.degradedFallback(
                prompt: job.fullPrompt,
                copiesTotal: job.copiesTotal
            )
            return
        }
        do {
            let built = try await registry.buildQueueStatusView(
                pluginID: job.pluginID,
                function: job.function,
                values: job.values,
                copiesTotal: job.copiesTotal,
                pluginUnavailable: job.pluginUnavailable
            )
            queue.jobs[index].statusView = built.statusView
            queue.jobs[index].thumbnailPaths = cardThumbnailPaths(built.thumbnailPaths)
            queue.jobs[index].fullPrompt = built.fullPrompt
            queue.jobs[index].referencesInvalid = built.referencesInvalid
        } catch {
            queue.jobs[index].statusView = QueueJobStatusView.degradedFallback(
                prompt: job.fullPrompt,
                copiesTotal: job.copiesTotal
            )
        }
    }

    func refreshActiveJobStatusView() async {
        guard activeJobID != nil, isEnabled else { return }
        let stepsLabel = jobAIStageActive ? "AI:" : "Steps:"
        do {
            let built = try await registry.buildQueueStatusView(
                pluginID: activePluginID,
                function: activeFunction,
                values: pendingValues,
                copiesTotal: copiesTotal,
                running: isProcessing,
                omitLiveStepsRow: true,
                withAI: jobAIStageActive,
                step: liveStepTotal > 0 ? liveStep : nil,
                stepTotal: liveStepTotal > 0 ? liveStepTotal : nil,
                elapsedSeconds: elapsedSeconds(),
                estimateSeconds: liveEstimateSeconds
            )
            activeStatusView = built.statusView
            activeThumbnailPaths = cardThumbnailPaths(built.thumbnailPaths)
        } catch {
            activeStatusView = QueueJobStatusView.degradedFallback(
                prompt: pendingValues["prompt"] as? String ?? "",
                copiesTotal: copiesTotal
            )
        }
        _ = stepsLabel
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
            if isEnabled, !pluginID.isEmpty {
                let success = try await registry.writeGenerationExif(
                    pluginID: pluginID,
                    values: values,
                    outputPath: outputPath,
                    workerResult: workerResult,
                    elapsedSeconds: elapsedSeconds,
                    localElapsed: elapsedSeconds,
                    fallbackSourcePaths: fallbackSourcePaths
                )
                guard success else { throw ExifService.ExifError.writeFailed }
                return
            }
            let comment: String
            if let prompt = values["prompt"] as? String {
                comment = prompt
            } else {
                comment = ""
            }
            try await ExifService.writeUserComment(path: outputPath, text: comment)
        } catch {
            return
        }
    }

    private func startLiveStatusTimer() {
        liveStatusTask?.cancel()
        liveStatusTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, self.isProcessing || self.cooldownSecondsRemaining > 0 else { break }
                await self.refreshActiveJobStatusView()
                await self.refreshActiveStripView()
                self.bumpQueueRevision()
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
        modelTasks.isBusy || foregroundTasks.isBusy
    }

    func hasPendingWork() -> Bool {
        !queue.jobs.isEmpty || isRunning() || activeJobID != nil
    }

    /// Return true when terminate may proceed without showing a dialog.
    func quitGateAllowsImmediateTerminate() -> Bool {
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
        startupQueueReleaseTask?.cancel()
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
            finishCopyBatchForDeferredQuit()
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
        finishCopyBatchForDeferredQuit()
        maybeQuitAfterCurrentWorker()
        return true
    }

    private func finishCopyBatchForDeferredQuit() {
        copyBatchActive = false
        copyBatchCancelled = true
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
        modelTasks.cancel()
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
        generationStartTime = nil
        liveStep = 0
        liveStepTotal = 0
        liveEstimateSeconds = nil
        skipSeriesCopyInFlight = false
        progressivePreviewPath = nil
        activeOutputPath = nil
        activeThumbnailPaths = []
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
            copiesDone = max(0, pendingDoc["steps_done"] as? Int ?? 0)
            if let display = pendingDoc["display"] as? [String: Any],
               let thumbs = display["thumbnail_paths"] as? [String] {
                activeThumbnailPaths = thumbs.filter { FileManager.default.fileExists(atPath: $0) }
            }
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
        if copyBatchActive, !copyBatchCancelled, pendingBatchCopies() > 0, !modelTasks.isBusy, cooldownSecondsRemaining == 0 {
            Task { await promoteAndRunNextStep() }
            return
        }
        if activeJobID != nil, !modelTasks.isBusy {
            resumeRestoredActiveJobIfIdle()
            return
        }
        if !modelTasks.isBusy {
            processNextIfIdle()
        }
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

    func refreshActiveStripView(includeQueueJobsRow: Bool = false) async {
        guard isEnabled, isProcessing || cooldownSecondsRemaining > 0 else {
            activeStripView = ActiveJobStripStatusView()
            return
        }
        let stepsLabel = jobAIStageActive ? "AI:" : "Steps:"
        let totalJobs = queueSnapshot().count
        do {
            activeStripView = try await registry.buildActiveJobStripView(
                elapsedSeconds: elapsedSeconds(),
                estimateSeconds: liveEstimateSeconds,
                step: liveStep,
                stepTotal: liveStepTotal,
                stepsLabel: stepsLabel,
                cooldownRemaining: cooldownSecondsRemaining,
                completedSeries: copiesDone,
                totalSeries: copiesTotal > 1 ? copiesTotal : nil,
                totalQueueJobs: includeQueueJobsRow ? totalJobs : nil,
                includeQueueJobsRow: includeQueueJobsRow
            )
        } catch {
            activeStripView = ActiveJobStripStatusView()
        }
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

private extension AppConfig {
    func imageGenInt(_ key: String, default defaultValue: Int) -> Int {
        let imagegen = rawSettings()["imagegen"] as? [String: Any] ?? [:]
        return imagegen[key] as? Int ?? defaultValue
    }
}
