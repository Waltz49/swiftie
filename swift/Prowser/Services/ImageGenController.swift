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
    private(set) var holdJobQueue = false
    private(set) var queueRevision = 0
    private(set) var dialogBuildPauseCount = 0

    private var skipSeriesCopyRequested = false
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
    private var selectedJobID: String?
    private var cooldownTask: Task<Void, Never>?

    var isEnabled: Bool { BundleCapabilities.imageGenUIEnabled && modelTasks.isAvailable && registry.isAvailable }

    var canSkipActiveSeriesCopy: Bool {
        isProcessing && !skipSeriesCopyRequested && copyBatchActive
    }

    var isDialogBuildPaused: Bool { dialogBuildPauseCount > 0 }

    var onImageGenerated: ((String) -> Void)?
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
        reloadQueue()
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
        queue = JobStepPersistence.loadQueue(config: config)
        activeDisplayIndex = queue.activeDisplayIndex
    }

    func reloadToolbarSettings(from imagegen: [String: Any]) {
        showProgressiveImages = imagegen["show_progressive_images"] as? Bool ?? false
        holdJobQueue = imagegen["hold_job_queue"] as? Bool ?? false
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
            processNextIfIdle()
        }
        bumpQueueRevision()
    }

    func skipActiveSeriesCopy() {
        guard canSkipActiveSeriesCopy else { return }
        skipSeriesCopyRequested = true
        if modelTasks.isBusy {
            modelTasks.cancel()
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
        submitValues = try await registry.normalizeValues(pluginID: pluginID, values: submitValues, mode: "snapshot")
        let steps = try await registry.materializeSteps(pluginID: pluginID, values: submitValues, copies: normalizedCopies)
        let prompt = submitValues["prompt"] as? String ?? ""
        let job = ImageGenQueuedJob(
            pluginID: pluginID,
            function: function,
            values: submitValues,
            copiesTotal: normalizedCopies,
            statusHTML: "Queued",
            fullPrompt: prompt,
            steps: steps
        )
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
                    thumbnailPaths: job.thumbnailPaths,
                    fullPrompt: job.fullPrompt,
                    referencesInvalid: job.referencesInvalid,
                    statusLabel: job.statusLabel
                )
            }
        if let activeJobID {
            let insertAt = max(0, min(activeDisplayIndex, rows.count))
            let activeRow = QueueRowSnapshot(
                jobID: activeJobID,
                isActive: true,
                statusHTML: taskStatusHTML.isEmpty ? progressMessage : taskStatusHTML,
                thumbnailPaths: activeThumbnailPaths,
                fullPrompt: pendingValues["prompt"] as? String ?? "",
                statusLabel: progressMessage
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
        bumpQueueRevision()
    }

    func jobsHeaderStatusText() -> String {
        let queued = queue.jobs.filter { $0.statusLabel == "Queued" || $0.statusHTML == "Queued" }.count
        if holdJobQueue && queued > 0 {
            return "=\(queued)"
        }
        if queued > 0 {
            return "+\(queued)"
        }
        return ""
    }

    // MARK: - Internal processing

    private func startNextQueuedJobIfIdle() async {
        guard isEnabled, !modelTasks.isBusy, activeJobID == nil, !holdJobQueue else { return }
        guard let index = queue.jobs.firstIndex(where: { $0.statusHTML == "Queued" || $0.statusLabel == "Queued" }) else {
            return
        }
        let job = queue.jobs[index]
        queue.jobs.remove(at: index)
        activeJobID = job.jobID
        activePluginID = job.pluginID
        activeFunction = job.function
        pendingValues = job.values
        copiesTotal = job.copiesTotal
        copiesDone = 0
        copyBatchActive = job.copiesTotal > 1
        activeThumbnailPaths = job.thumbnailPaths
        activeDisplayIndex = index
        stepPendingDoc = JobStepQueue.buildPendingJobDoc(
            jobID: job.jobID,
            pluginID: job.pluginID,
            function: job.function,
            steps: job.steps,
            fullPrompt: job.fullPrompt,
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
        progressMessage = "Starting…"
        taskStatusHTML = progressMessage
        bumpQueueRevision()

        let values = JobStepQueue.mergeStepIntoValues(step)
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
            _ = try modelTasks.startGenerate(payload: payload)
            bumpQueueRevision()
        } catch {
            handleStepFailure(error.localizedDescription)
        }
    }

    private func handleGenerateFinished(success: Bool, outputPath: String, error: String) {
        defer {
            skipSeriesCopyRequested = false
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
            if let prompt = pendingValues["prompt"] as? String {
                try? ExifService.writeUserComment(path: outputPath, text: prompt)
            }
            onImageGenerated?(outputPath)
            lastError = ""
            progressMessage = "Done"
        } else {
            lastError = error
            if error == "Cancelled" {
                finishActiveJob(cancelled: true)
                return
            }
        }

        stepRunning = nil
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
        progressivePreviewPath = nil
        stepRunning = nil
        stepPendingDoc = nil
        copyBatchActive = false
        copiesTotal = 0
        copiesDone = 0
        jobAIStageActive = false
        JobStepPersistence.saveActiveRunning(nil, config: config)
        JobStepPersistence.saveActivePending(nil, config: config)
        persistQueue()
        bumpQueueRevision()
        if !holdJobQueue {
            Task { await startNextQueuedJobIfIdle() }
        }
    }

    private func handleStepFailure(_ message: String) {
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
        let ms = config.imageGenInt("job_cooldown_ms", default: 0)
        cooldownTask = Task {
            if ms > 0 {
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            }
            guard !Task.isCancelled else { return }
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
        queue.activeDisplayIndex = activeDisplayIndex
        JobStepPersistence.saveQueue(queue, config: config)
    }

    private func persistStepState() {
        JobStepPersistence.persistStepJobFiles(
            running: stepRunning != nil ? JobStepPersistence.loadActiveRunning(config: config) : nil,
            pending: stepPendingDoc,
            queue: queue,
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
            if let path = message["progressive_output_path"] as? String ?? message["preview_path"] as? String {
                self.progressivePreviewPath = path
            }
            if let step = message["step"] {
                self.progressMessage = "Step \(step)"
                self.taskStatusHTML = self.progressMessage
            }
            self.bumpQueueRevision()
        }
        modelTasks.onGenerateFinished = { [weak self] success, outputPath, error in
            self?.handleGenerateFinished(success: success, outputPath: outputPath, error: error)
        }
        modelTasks.onJobFinished = { [weak self] kind, success, error in
            guard kind == "generate", let self else { return }
            if !success, self.activeJobID != nil {
                self.handleGenerateFinished(success: false, outputPath: "", error: error)
            }
        }
    }

    private func mutateImagegen(_ mutate: (inout [String: Any]) -> Void) {
        var imagegen = config.rawSettings()["imagegen"] as? [String: Any] ?? [:]
        mutate(&imagegen)
        config.updateSetting("imagegen", value: imagegen)
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
