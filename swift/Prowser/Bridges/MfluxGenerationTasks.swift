import Foundation

/// Runs one MFLUX CLI job at a time (replaces Python `model_tasks_worker` for generate).
@MainActor
final class MfluxGenerationTasks {
    private weak var config: AppConfig?

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

    var workerNeedsCleanup: Bool { false }

    func bind(config: AppConfig) {
        self.config = config
    }

    func startGenerate(payload: [String: Any]) throws -> String {
        guard !isBusy else { throw BridgeError.busy }
        let pipelineID = payload["pipeline_id"] as? String ?? ""
        let hfModelID = payload["hf_model_id"] as? String ?? ""
        if ImageGenPipelineRouting.usesPythonWorker(pipelineID: pipelineID, hfModelID: hfModelID) {
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

    func cancel() {
        cancelled = true
        stepwiseWatcher?.stop()
        if let process, process.isRunning {
            process.terminate()
        }
        finishJob(success: false, outputPath: "", error: "Cancelled")
    }

    @discardableResult
    func unloadImageModel() -> Bool { true }

    func shutdown() {
        cancel()
        runTask?.cancel()
        runTask = nil
    }

    private func runGenerate(payload: [String: Any], jobID: String) async {
        onJobProcessingStarted?("generate")
        do {
            let userOutputPath = payload["output_path"] as? String ?? ""
            var runPayload = try await ImageGenMfluxPrep.apply(to: payload)
            let pipelineID = runPayload["pipeline_id"] as? String ?? ""
            let hfModelID = runPayload["hf_model_id"] as? String ?? payload["hf_model_id"] as? String ?? ""
            let usePythonWorker = ImageGenPipelineRouting.usesPythonWorker(
                pipelineID: pipelineID,
                hfModelID: hfModelID
            )
            if !usePythonWorker {
                guard MfluxToolchain.shared.executableURL(forPipeline: pipelineID) != nil else {
                    throw MfluxCLIError.unsupportedPipeline(pipelineID)
                }
            }
            let steps = (runPayload["steps"] as? Int) ?? (runPayload["steps"] as? NSNumber)?.intValue ?? 4
            let finalOutputPath = (runPayload["_klein_expand_post"] as? [String: String])?["final_output"]
                ?? userOutputPath
            let directCLIPath = runPayload["output_path"] as? String ?? userOutputPath
            let stepwiseDir = (runPayload["stepwise_image_output_dir"] as? String)
                ?? StepwisePaths.makeStepwiseDir(steps: steps)
            runPayload["stepwise_image_output_dir"] = stepwiseDir
            let progressive = runPayload["progressive_output_path"] as? String

            stepwiseWatcher = StepwiseProgressWatcher(
                stepwiseDir: stepwiseDir,
                progressiveOutputPath: progressive,
                expectedSteps: steps,
                onProgress: { [weak self] message in
                    Task { @MainActor in
                        self?.onProgress?(message)
                    }
                }
            )
            stepwiseWatcher?.start()

            if usePythonWorker {
                guard let config,
                      let pyEnv = PythonLocator.resolve(profilePath: nil, config: config) else {
                    throw MfluxCLIError.processFailed(
                        "Python environment not configured (Settings → Image Generation)."
                    )
                }
                runPayload["output_path"] = finalOutputPath
                let workerRun = try await ImageGenPipelineWorkerRunner.run(
                    pipelineID: pipelineID,
                    payload: runPayload,
                    environment: pyEnv
                ) { [weak self] proc in
                    self?.process = proc
                }
                stepwiseWatcher?.stop()
                stepwiseWatcher = nil
                process = nil
                if cancelled {
                    finishJob(success: false, outputPath: finalOutputPath, error: "Cancelled")
                    return
                }
                guard workerRun.exitStatus == 0 else {
                    throw MfluxCLIError.processFailed(
                        workerFailureMessage(
                            stdout: workerRun.stdoutText,
                            stderr: workerRun.stderrText,
                            status: workerRun.exitStatus
                        )
                    )
                }
                if let workerDoc = parseWorkerJSON(workerRun.stdoutText),
                   let out = workerDoc["output_path"] as? String,
                   !out.isEmpty {
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
                    self?.process = proc
                }
                stepwiseWatcher?.stop()
                stepwiseWatcher = nil
                process = nil

                if cancelled {
                    finishJob(success: false, outputPath: finalOutputPath, error: "Cancelled")
                    return
                }
                guard runResult.exitStatus == 0 else {
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
            finishJob(success: true, outputPath: finalOutput, error: "")
        } catch {
            stepwiseWatcher?.stop()
            stepwiseWatcher = nil
            process = nil
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            finishJob(success: false, outputPath: "", error: message)
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

    private func finishJob(success: Bool, outputPath: String, error: String) {
        let kind = activeKind
        isBusy = false
        activeKind = ""
        activeJobID = ""
        if kind == "generate" {
            onGenerateFinished?(success, outputPath, error)
        }
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
