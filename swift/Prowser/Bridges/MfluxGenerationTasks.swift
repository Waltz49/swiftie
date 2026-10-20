import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Runs one image generation job at a time (optimized Python worker or MFLUX CLI).
@MainActor
final class MfluxGenerationTasks {
    private weak var config: AppConfig?
    private let generationWorker = ImageGenGenerationWorker()

    private(set) var isReady = true
    private(set) var isBusy = false
    private(set) var activeJobID = ""
    private(set) var activeKind = ""
    private(set) var lastError = ""
    private(set) var lastGenerateResult: [String: Any] = [:]

    var onJobProcessingStarted: ((String) -> Void)?
    var onProgress: (([String: Any]) -> Void)?
    var onGenerateFinished: ((Bool, String, String) -> Void)?

    private var process: Process?
    private var runTask: Task<Void, Never>?
    private var stepwiseWatcher: StepwiseProgressWatcher?
    private var cancelled = false

    var isAvailable: Bool { MfluxToolchain.shared.isAvailable }

    var workerNeedsCleanup: Bool {
        generationWorker.unloadInFlight
    }

    func bind(config: AppConfig) {
        self.config = config
        generationWorker.bind(config: config)
    }

    func startGenerate(payload: [String: Any]) throws -> String {
        guard !isBusy else { throw BridgeError.busy }
        let pipelineID = payload["pipeline_id"] as? String ?? ""
        let hfModelID = payload["hf_model_id"] as? String ?? ""
        if ImageGenPipelineRouting.usesPythonWorker(
            pipelineID: pipelineID,
            hfModelID: hfModelID,
            config: config
        ) {
            guard let config,
                  FileManager.default.isExecutableFile(atPath: config.imagegenVenvPythonPath()),
                  PythonLocator.resolve(profilePath: nil, config: config) != nil else {
                throw BridgeError.pythonUnavailable
            }
        } else {
            guard isAvailable else { throw BridgeError.pythonUnavailable }
            guard MfluxCLIPipeline.isSupported(pipelineID: pipelineID),
                  MfluxToolchain.shared.isPipelineInstalled(pipelineID) else {
                throw MfluxCLIError.unsupportedPipeline(pipelineID)
            }
        }
        let jobID = UUID().uuidString
        activeJobID = jobID
        activeKind = "generate"
        isBusy = true
        cancelled = false
        lastError = ""
        lastGenerateResult = [:]

        runTask = Task { [weak self] in
            await self?.runGenerate(payload: payload, jobID: jobID)
        }
        return jobID
    }

    func cancel(terminateWorker: Bool = false) {
        guard isBusy else { return }
        cancelled = true
        stepwiseWatcher?.stop()
        terminateTrackedProcess(force: false)
        let jobID = activeJobID
        Task {
            await generationWorker.requestCancel(
                activeJobID: jobID,
                terminateWorker: terminateWorker
            )
        }
        // Keep the task busy until the terminated process has actually unwound. Advancing
        // synchronously here lets its stale completion overwrite the next copy/job's state.
    }

    @discardableResult
    func unloadImageModel() -> Bool {
        Task { await generationWorker.unloadImageModel() }
        return true
    }

    func shutdown() {
        guard isBusy else {
            runTask?.cancel()
            runTask = nil
            Task { await generationWorker.shutdown() }
            return
        }
        cancelled = true
        stepwiseWatcher?.stop()
        terminateTrackedProcess(force: true)
        runTask?.cancel()
        runTask = nil
        let jobID = activeJobID
        if !jobID.isEmpty {
            finishJob(jobID: jobID, success: false, outputPath: "", error: "Cancelled")
        }
        Task { await generationWorker.shutdown() }
    }

    /// SIGTERM (and SIGKILL when ``force``), port of Python ``ModelTasksController._terminate_worker`` / ``force_terminate_worker``.
    private func terminateTrackedProcess(force: Bool) {
        guard let process, process.isRunning else { return }
        process.terminate()
        guard force else { return }
        let pid = process.processIdentifier
        let deadline = Date().addingTimeInterval(2.0)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            #if canImport(Darwin)
            kill(pid, SIGKILL)
            #endif
            let killDeadline = Date().addingTimeInterval(3.0)
            while process.isRunning, Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    private func runGenerate(payload: [String: Any], jobID: String) async {
        onJobProcessingStarted?("generate")
        do {
            let userOutputPath = payload["output_path"] as? String ?? ""
            var runPayload = try await ImageGenMfluxPrep.apply(to: payload)
            let prepTempPaths = ImageGenMfluxPrep.takePrepTempPaths(from: &runPayload)
            defer {
                let debug = config?.bool(forKey: "debug_mode", default: false) ?? false
                ImageGenMfluxPrep.removePrepTempFiles(prepTempPaths, debugMode: debug)
            }
            let pipelineID = runPayload["pipeline_id"] as? String ?? ""
            let hfModelID = runPayload["hf_model_id"] as? String ?? payload["hf_model_id"] as? String ?? ""
            let usePythonWorker = ImageGenPipelineRouting.usesPersistentPythonWorker(
                pipelineID: pipelineID,
                hfModelID: hfModelID,
                config: config
            )
            guard jobID == activeJobID, !cancelled else {
                finishJob(jobID: jobID, success: false, outputPath: "", error: "Cancelled")
                return
            }
            if !usePythonWorker {
                guard MfluxToolchain.shared.executableURL(forPipeline: pipelineID) != nil else {
                    throw MfluxCLIError.unsupportedPipeline(pipelineID)
                }
            }
            let steps = (runPayload["steps"] as? Int) ?? (runPayload["steps"] as? NSNumber)?.intValue ?? 4
            let finalOutputPath = (runPayload["_klein_expand_post"] as? [String: String])?["final_output"]
                ?? userOutputPath
            let directCLIPath = runPayload["output_path"] as? String ?? userOutputPath
            let progressive = (runPayload["progressive_output_path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? finalOutputPath
            let progressHandler: ([String: Any]) -> Void = { [weak self] message in
                let enriched = Self.enrichProgressMessage(message, progressiveOutputPath: progressive)
                self?.onProgress?(enriched)
            }

            // MFLUX CLI writes seed_*_stepNofM.png into stepwise_image_output_dir; Swift copies to
            // progressive_output_path. Python workers (SD15/SDXL VAE previews, run_with_stepwise_watcher)
            // emit NDJSON progress on stderr instead.
            if !usePythonWorker,
               let stepwiseDir = runPayload["stepwise_image_output_dir"] as? String,
               !stepwiseDir.isEmpty {
                stepwiseWatcher = StepwiseProgressWatcher(
                    stepwiseDir: stepwiseDir,
                    progressiveOutputPath: progressive,
                    expectedSteps: steps,
                    onProgress: progressHandler
                )
                stepwiseWatcher?.start()
            }

            if usePythonWorker {
                if let config, config.bool(forKey: "debug_mode", default: false) {
                    let pipeline = runPayload["pipeline_id"] as? String ?? ""
                    config.debugLog(
                        "[imagegen] optimized worker pipeline=\(pipeline) steps=\(steps)"
                    )
                }
                guard let config else {
                    throw MfluxCLIError.processFailed(
                        "Python environment not configured (Settings → Image Generation)."
                    )
                }
                let hfForCheck = hfModelID.trimmingCharacters(in: .whitespacesAndNewlines)
                if !hfForCheck.isEmpty,
                   !ImageGenHFModelLocality.modelIsInstalled(pipelineID: pipelineID, repoID: hfForCheck) {
                    throw MfluxCLIError.processFailed(
                        "Model weights for \(hfForCheck) are not installed locally. "
                            + "Use Image → Manage models… to download, then try again."
                    )
                }
                progressHandler([
                    "type": "progress",
                    "step": 0,
                    "step_total": steps,
                    "phase": "loading_model",
                ])
                runPayload["output_path"] = finalOutputPath
                if let flag = runPayload["show_progressive_images"] {
                    runPayload["show_progressive_images"] = ImageGenPipelineModes.boolFromSettingsValue(flag)
                } else {
                    runPayload["show_progressive_images"] = ImageGenPipelineModes.showProgressiveImages(config: config)
                }
                if config.bool(forKey: "debug_mode", default: false) {
                    runPayload["debug_mode"] = true
                }
                let workerDoc = try await generationWorker.runGenerate(
                    payload: runPayload,
                    jobID: jobID,
                    onProgress: progressHandler
                )
                if cancelled {
                    finishJob(jobID: jobID, success: false, outputPath: finalOutputPath, error: "Cancelled")
                    return
                }
                if let out = workerDoc["output_path"] as? String, !out.isEmpty {
                    lastGenerateResult = workerDoc
                } else if FileManager.default.fileExists(atPath: finalOutputPath) {
                    lastGenerateResult = ["output_path": finalOutputPath, "success": true]
                } else {
                    throw MfluxCLIError.processFailed("Python worker returned no output path.")
                }
            } else {
                guard let executable = MfluxToolchain.shared.executableURL(forPipeline: pipelineID) else {
                    throw MfluxCLIError.unsupportedPipeline(pipelineID)
                }
                let usesTempCLI = directCLIPath == finalOutputPath
                let mfluxCLIPath = usesTempCLI
                    ? ImageGenMfluxPrep.mfluxTempOutputPath(for: finalOutputPath)
                    : directCLIPath
                try? FileManager.default.removeItem(atPath: mfluxCLIPath)
                runPayload["output_path"] = mfluxCLIPath
                let args = try MfluxCLIPipeline.buildArguments(payload: runPayload)
                let env = MfluxToolchain.shared.processEnvironment()
                let request = MfluxProcessRunner.Request(
                    executableURL: executable,
                    arguments: args,
                    environment: env
                )

                let runResult = try await MfluxProcessRunner.run(request) { [weak self] proc in
                    guard let self, self.activeJobID == jobID else {
                        if proc.isRunning { proc.terminate() }
                        return
                    }
                    self.process = proc
                    if self.cancelled, proc.isRunning {
                        proc.terminate()
                    }
                }
                await stepwiseWatcher?.flushAndStop()
                process = nil

                if cancelled {
                    stepwiseWatcher = nil
                    finishJob(jobID: jobID, success: false, outputPath: finalOutputPath, error: "Cancelled")
                    return
                }
                guard runResult.exitStatus == 0 else {
                    stepwiseWatcher = nil
                    let tail = runResult.stderrText
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .split(separator: "\n")
                        .suffix(6)
                        .joined(separator: "\n")
                    let detail = tail.isEmpty ? "" : "\n\n\(tail)"
                    throw MfluxCLIError.processFailed(
                        "mflux exited with status \(runResult.exitStatus).\(detail)"
                    )
                }
                if usesTempCLI {
                    try ImageGenMfluxPrep.promoteMfluxOutput(cliPath: mfluxCLIPath, finalPath: finalOutputPath)
                }
                stepwiseWatcher?.emitFinalStepProgress()
                stepwiseWatcher = nil
                var result: [String: Any] = ["output_path": finalOutputPath, "success": true]
                if let seed = runPayload["resolved_seed"] {
                    result["seed"] = seed
                }
                lastGenerateResult = result
            }

            var finalOutput = (lastGenerateResult["output_path"] as? String) ?? finalOutputPath
            finalOutput = (try? ImageGenMfluxPrep.finalizeKleinExpandIfNeeded(
                payload: runPayload,
                cliOutputPath: finalOutput
            )) ?? finalOutput
            guard FileManager.default.fileExists(atPath: finalOutput) else {
                throw MfluxCLIError.processFailed("MFLUX did not write output at \(finalOutput)")
            }
            lastGenerateResult["output_path"] = finalOutput
            lastGenerateResult["success"] = true
            finishJob(jobID: jobID, success: true, outputPath: finalOutput, error: "")
        } catch {
            stepwiseWatcher?.stop()
            stepwiseWatcher = nil
            process = nil
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if jobID == activeJobID, cancelled || message == "Cancelled" {
                finishJob(jobID: jobID, success: false, outputPath: "", error: "Cancelled")
                return
            }
            finishJob(jobID: jobID, success: false, outputPath: "", error: message)
        }
    }

    private func parseWorkerJSON(_ stdout: String) -> [String: Any]? {
        let lines = stdout.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if obj["output_path"] != nil || obj["error"] != nil {
                return obj
            }
        }
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private func workerFailureMessage(stdout: String, stderr: String, status: Int32) -> String {
        if let doc = parseWorkerJSON(stderr), let err = doc["error"] as? String {
            return err
        }
        let tail = (stderr.isEmpty ? stdout : stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .suffix(6)
            .joined(separator: "\n")
        if tail.isEmpty {
            return "SceneWorks Klein worker exited with status \(status)."
        }
        return "SceneWorks Klein worker exited with status \(status).\n\n\(tail)"
    }

    private func finishJob(jobID: String, success: Bool, outputPath: String, error: String) {
        guard jobID == activeJobID else { return }
        let kind = activeKind
        isBusy = false
        activeKind = ""
        activeJobID = ""
        process = nil
        runTask = nil
        cancelled = false
        if kind == "generate" {
            onGenerateFinished?(success, outputPath, error)
        }
    }

    /// SD15/SDXL workers emit ``path`` only when a VAE preview lands; keep browse target aligned with Python.
    private static func enrichProgressMessage(
        _ message: [String: Any],
        progressiveOutputPath: String
    ) -> [String: Any] {
        var msg = message
        let progressive = progressiveOutputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !progressive.isEmpty else { return msg }

        let hasPath = (msg["path"] as? String)?.isEmpty == false
            || (msg["preview_path"] as? String)?.isEmpty == false
        if !hasPath, FileManager.default.fileExists(atPath: progressive) {
            msg["path"] = progressive
            msg["progressive_output_path"] = progressive
        }
        return msg
    }
}

enum StepwisePaths {
    static func makeStepwiseDir(steps: Int) -> String {
        let base = ProwserTempFiles.imageGenProgressDirectory()
        let dir = (base as NSString).appendingPathComponent("stepwise-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
}
