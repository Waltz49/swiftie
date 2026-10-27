import Foundation

/// Persistent ``workers.imagegen_generate_worker`` subprocess (optimized pipelines).
@MainActor
final class ImageGenGenerationWorker {
    typealias ProgressHandler = ([String: Any]) -> Void

    private let ndjson = PythonNDJSONWorker(module: "workers.imagegen_generate_worker")
    private weak var config: AppConfig?
    private(set) var unloadInFlight = false
    private(set) var processMayRetainModel = false
    /// True while ``requestCancel(terminateWorker:)`` is reaping the NDJSON subprocess (Python ``worker_needs_cleanup``).
    private(set) var workerTeardownActive = false

    var retainsWorkerProcess: Bool {
        processMayRetainModel
    }

    func bind(config: AppConfig?) {
        self.config = config
    }

    func runGenerate(
        payload: [String: Any],
        jobID: String,
        onProgress: @escaping ProgressHandler
    ) async throws -> [String: Any] {
        guard let config,
              let environment = PythonLocator.resolve(profilePath: nil, config: config) else {
            throw BridgeError.pythonUnavailable
        }
        await ndjson.bind(environment: environment)
        let wasRunning = await ndjson.running
        if !wasRunning {
            ImageGenCommandLog.printPythonModuleInvocation(
                executablePath: environment.executable,
                module: "workers.imagegen_generate_worker"
            )
        }
        let debugMode = config.bool(forKey: "debug_mode", default: false)
        if debugMode {
            let pipeline = payload["pipeline_id"] as? String ?? ""
            config.debugLog("[imagegen] generate job_id=\(jobID) pipeline=\(pipeline)")
        }
        await ndjson.setStderrLineHandler { line in
            guard debugMode else { return }
            ImageGenCommandLog.appendWorkerLine(line)
            NSLog("%@", line)
        }
        let sendableProgress: PythonNDJSONWorker.ProgressHandler = { message in
            onProgress(message)
        }
        processMayRetainModel = true
        return try await ndjson.send(
            [
                "command": "generate",
                "job_id": jobID,
                "payload": payload,
            ],
            awaitFinalResult: true,
            onProgress: sendableProgress
        )
    }

    func requestCancel(activeJobID: String? = nil, terminateWorker: Bool = false) async {
        if terminateWorker {
            workerTeardownActive = true
        }
        defer {
            if terminateWorker {
                workerTeardownActive = false
            }
        }
        if await ndjson.running {
            var command: [String: Any] = ["command": "cancel"]
            if let activeJobID, !activeJobID.isEmpty {
                command["job_id"] = activeJobID
            }
            try? await ndjson.writeCommand(command)
        }
        if terminateWorker {
            await ndjson.terminateForCancel()
            processMayRetainModel = false
        }
    }

    func workerSubprocessNeedsCleanup() async -> Bool {
        await ndjson.subprocessNeedsCleanup()
    }

    func forceTerminateWorker() async {
        workerTeardownActive = true
        defer { workerTeardownActive = false }
        await ndjson.terminateForCancel()
        processMayRetainModel = false
    }

    /// Blocks starting another generate (unload or in-flight worker kill after skip escalation).
    var blocksLaunch: Bool {
        unloadInFlight || workerTeardownActive
    }

    /// Status bar “cleanup” dot — model unload only, not brief skip teardown.
    var indicatesStatusBarCleanup: Bool {
        unloadInFlight
    }

    func unloadImageModel() async {
        guard let config,
              let environment = PythonLocator.resolve(profilePath: nil, config: config) else {
            return
        }
        await ndjson.bind(environment: environment)
        guard await ndjson.running else {
            processMayRetainModel = false
            return
        }
        unloadInFlight = true
        defer { unloadInFlight = false }
        _ = try? await ndjson.send(
            ["command": "unload_image", "job_id": UUID().uuidString],
            awaitFinalResult: false
        )
        processMayRetainModel = false
    }

    func shutdown() async {
        await ndjson.shutdown()
        processMayRetainModel = false
    }
}
