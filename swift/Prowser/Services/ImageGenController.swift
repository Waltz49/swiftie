import Foundation

/// Swift port of `imagegen_plugins/image_gen_controller.py` (phase 1 — queue + generate).
@Observable
@MainActor
final class ImageGenController {
    private let config: AppConfig
    private let modelTasks: ModelTasksBridge

    private(set) var queue: ImageGenQueueFile = ImageGenQueueFile()
    private(set) var activeJobID: String?
    private(set) var isProcessing = false
    private(set) var lastError = ""
    private(set) var progressMessage = ""
    private(set) var progressivePreviewPath: String?
    private(set) var showProgressiveImages = false
    private(set) var holdJobQueue = false
    private var skipSeriesCopyRequested = false

    var isEnabled: Bool { BundleCapabilities.imageGenUIEnabled && modelTasks.isAvailable }

    var canSkipActiveSeriesCopy: Bool {
        isProcessing && !skipSeriesCopyRequested
    }

    var onImageGenerated: ((String) -> Void)?

    init(config: AppConfig, modelTasks: ModelTasksBridge) {
        self.config = config
        self.modelTasks = modelTasks
        reloadQueue()
        wireBridgeCallbacks()
    }

    func reloadQueue() {
        queue = JobStepPersistence.loadQueue(config: config)
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
    }

    func skipActiveSeriesCopy() {
        guard canSkipActiveSeriesCopy else { return }
        skipSeriesCopyRequested = true
    }

    func enqueueCreate(prompt: String, width: Int = 1024, height: Int = 1024) throws {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ImageGenError.emptyPrompt
        }
        let values: [String: Any] = [
            "prompt": trimmed,
            "width": width,
            "height": height,
            "pipeline_id": "flux_schnell_mflux_play",
            "plugin_id": "flux_schnell_play",
            "steps": 4,
            "guidance_scale": 3.5,
            "random_seed": true,
            "hf_model_id": "black-forest-labs/FLUX.1-schnell",
            "mflux_quantize": 3,
            "low_ram": false,
            "max_generation_dimension": 1536,
        ]
        let job = ImageGenQueuedJob(
            pluginID: "flux_schnell_play",
            function: "create",
            values: values,
            copiesTotal: 1,
            statusLabel: "Queued"
        )
        queue.jobs.append(job)
        persistQueue()
        processNextIfIdle()
    }

    func cancelActiveJob() {
        modelTasks.cancel()
        if let activeJobID,
           let index = queue.jobs.firstIndex(where: { $0.jobID == activeJobID }) {
            queue.jobs[index].statusLabel = "Cancelled"
        }
        activeJobID = nil
        isProcessing = false
        progressMessage = ""
        progressivePreviewPath = nil
        JobStepPersistence.saveActiveRunning(nil, config: config)
        persistQueue()
        processNextIfIdle()
    }

    func removeJob(id: String) {
        queue.jobs.removeAll { $0.jobID == id }
        persistQueue()
    }

    private func processNextIfIdle() {
        guard isEnabled, !modelTasks.isBusy, activeJobID == nil, !holdJobQueue else { return }
        guard let index = queue.jobs.firstIndex(where: { $0.statusLabel == "Queued" }) else { return }
        let job = queue.jobs[index]
        activeJobID = job.jobID
        isProcessing = true
        queue.jobs[index].statusLabel = "Starting…"
        persistQueue()

        let outputPath = ImageGenPathNaming.nextImageGenPath(config: config, ext: ".png")
        var payload = job.values
        payload["output_path"] = outputPath
        payload["pipeline_id"] = payload["pipeline_id"] ?? "flux_schnell_mflux_play"
        payload["debug_mode"] = config.bool(forKey: "debug_mode")

        JobStepPersistence.saveActiveRunning([
            "job_id": job.jobID,
            "output_path": outputPath,
            "function": job.function,
        ], config: config)

        do {
            _ = try modelTasks.startGenerate(payload: payload)
            queue.jobs[index].statusLabel = "Generating…"
            persistQueue()
        } catch {
            lastError = error.localizedDescription
            queue.jobs[index].statusLabel = "Failed"
            activeJobID = nil
            isProcessing = false
            JobStepPersistence.saveActiveRunning(nil, config: config)
            persistQueue()
        }
    }

    private func wireBridgeCallbacks() {
        modelTasks.onJobProcessingStarted = { [weak self] kind in
            guard let self else { return }
            if kind == "generate" {
                self.progressMessage = "Generating…"
            }
        }
        modelTasks.onProgress = { [weak self] message in
            guard let self else { return }
            if let path = message["progressive_output_path"] as? String ?? message["preview_path"] as? String {
                self.progressivePreviewPath = path
            }
            if let step = message["step"] {
                self.progressMessage = "Step \(step)"
            }
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

    private func handleGenerateFinished(success: Bool, outputPath: String, error: String) {
        defer {
            activeJobID = nil
            isProcessing = false
            progressMessage = ""
            progressivePreviewPath = nil
            JobStepPersistence.saveActiveRunning(nil, config: config)
            persistQueue()
            processNextIfIdle()
        }

        guard let jobID = activeJobID,
              let index = queue.jobs.firstIndex(where: { $0.jobID == jobID }) else { return }

        if success, !outputPath.isEmpty {
            queue.jobs[index].statusLabel = "Done"
            if let prompt = queue.jobs[index].values["prompt"] as? String {
                try? ExifService.writeUserComment(path: outputPath, text: prompt)
            }
            onImageGenerated?(outputPath)
            lastError = ""
        } else {
            queue.jobs[index].statusLabel = error == "Cancelled" ? "Cancelled" : "Failed"
            lastError = error
        }
    }

    private func persistQueue() {
        JobStepPersistence.saveQueue(queue, config: config)
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

    var errorDescription: String? {
        switch self {
        case .emptyPrompt: return "Prompt is required."
        case .unavailable: return "Image generation is not available."
        }
    }
}
