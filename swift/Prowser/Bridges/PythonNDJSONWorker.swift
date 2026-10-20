import Foundation

/// Long-lived stdin/stdout NDJSON worker (Python ``workers.ipc_json`` protocol).
actor PythonNDJSONWorker {
    typealias ProgressHandler = @Sendable ([String: Any]) -> Void
    typealias StderrLineHandler = @Sendable (String) -> Void

    /// First launch can block on Python imports before the ``ready`` line (e.g. LoRA bridge).
    private static let startupReadyTimeout: TimeInterval = 90

    private let moduleName: String?
    private let scriptURL: URL?
    private var environment: PythonLocator.Environment?
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readTask: Task<Void, Never>?
    private var stderrDrainTask: Task<Void, Never>?
    private var isReady = false
    private var pending: [String: PendingRequest] = [:]
    private var shuttingDown = false
    private var lineBuffer = Data()
    private var stderrLineBuffer = Data()
    private var onStderrLine: StderrLineHandler?

    private struct PendingRequest {
        var continuation: CheckedContinuation<[String: Any], Error>
        var onProgress: ProgressHandler?
        var awaitFinalResult: Bool
    }

    init(module: String) {
        moduleName = module
        scriptURL = nil
    }

    init(scriptURL: URL) {
        moduleName = nil
        self.scriptURL = scriptURL
    }

    func bind(environment: PythonLocator.Environment?) async {
        if let environment {
            if let current = self.environment,
               current.executable == environment.executable,
               current.bundleRoot == environment.bundleRoot,
               current.profilePath == environment.profilePath {
                return
            }
            if self.environment != nil {
                await shutdownInternal()
            }
            self.environment = environment
            return
        }
        if self.environment != nil {
            await shutdownInternal()
        }
        self.environment = nil
    }

    var running: Bool {
        process?.isRunning == true && isReady
    }

    func setStderrLineHandler(_ handler: StderrLineHandler?) {
        onStderrLine = handler
    }

    func startIfNeeded() async throws {
        if running { return }
        guard let environment else { throw BridgeError.pythonUnavailable }
        if let process, process.isRunning {
            try await waitForReady()
            return
        }

        isReady = false
        shuttingDown = false
        lineBuffer = Data()
        stderrLineBuffer = Data()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: environment.executable)
        if let scriptURL {
            proc.arguments = ["-u", scriptURL.path]
        } else if let moduleName {
            proc.arguments = PythonLocator.moduleArguments(moduleName)
        } else {
            throw BridgeError.pythonUnavailable
        }
        proc.currentDirectoryURL = environment.bundleRoot
        proc.environment = PythonLocator.processEnvironment(for: environment)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        process = proc
        stdinHandle = stdinPipe.fileHandleForWriting

        let stdout = stdoutPipe.fileHandleForReading
        let stderr = stderrPipe.fileHandleForReading
        let worker = self
        readTask = Task.detached {
            while !Task.isCancelled {
                let chunk = stdout.availableData
                if chunk.isEmpty { break }
                await worker.appendStdout(chunk)
            }
        }
        let procRef = proc
        stderrDrainTask = Task.detached {
            while !Task.isCancelled {
                let chunk = stderr.availableData
                if chunk.isEmpty {
                    if !procRef.isRunning {
                        break
                    }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    continue
                }
                await worker.appendStderr(chunk)
            }
            let trailing = stderr.readDataToEndOfFile()
            if !trailing.isEmpty {
                await worker.appendStderr(trailing)
            }
        }

        try proc.run()
        try await ensureReady(timeout: Self.startupReadyTimeout)
    }

    private func waitForReady() async throws {
        try await ensureReady(timeout: Self.startupReadyTimeout)
    }

    func ensureReady(timeout: TimeInterval) async throws {
        if isReady { return }
        let attempts = max(1, Int((timeout * 10).rounded(.up)))
        for _ in 0..<attempts {
            if isReady { return }
            if shuttingDown { throw BridgeError.notReady }
            if let process, !process.isRunning, !isReady {
                throw BridgeError.workerNotRunning
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        if !isReady { throw BridgeError.notReady }
    }

    /// Write a command without waiting for a response (e.g. ``cancel`` while ``generate`` is in flight).
    func writeCommand(_ command: [String: Any]) async throws {
        try await startIfNeeded()
        try await waitForReady()
        guard let stdinHandle else { throw BridgeError.workerNotRunning }

        var payload = command
        if (payload["job_id"] as? String)?.isEmpty != false {
            payload["job_id"] = UUID().uuidString
        }

        let lineData = try JSONSerialization.data(withJSONObject: payload)
        guard var line = String(data: lineData, encoding: .utf8) else {
            throw BridgeError.encodingFailed
        }
        line.append("\n")
        guard let bytes = line.data(using: .utf8) else { throw BridgeError.encodingFailed }
        try stdinHandle.write(contentsOf: bytes)
    }

    func send(
        _ command: [String: Any],
        awaitFinalResult: Bool = false,
        onProgress: ProgressHandler? = nil
    ) async throws -> [String: Any] {
        try await startIfNeeded()
        try await waitForReady()
        guard let stdinHandle else { throw BridgeError.workerNotRunning }

        let jobID = (command["job_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        var payload = command
        payload["job_id"] = jobID

        let lineData = try JSONSerialization.data(withJSONObject: payload)
        guard var line = String(data: lineData, encoding: .utf8) else {
            throw BridgeError.encodingFailed
        }
        line.append("\n")
        guard let bytes = line.data(using: .utf8) else { throw BridgeError.encodingFailed }

        return try await withCheckedThrowingContinuation { continuation in
            pending[jobID] = PendingRequest(
                continuation: continuation,
                onProgress: onProgress,
                awaitFinalResult: awaitFinalResult
            )
            do {
                try stdinHandle.write(contentsOf: bytes)
            } catch {
                pending.removeValue(forKey: jobID)
                continuation.resume(throwing: error)
            }
        }
    }

    /// Stop the worker subprocess and fail in-flight requests (port of Python ``force_terminate_worker``).
    func terminateForCancel() async {
        readTask?.cancel()
        readTask = nil
        stderrDrainTask?.cancel()
        stderrDrainTask = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        stdinHandle = nil
        isReady = false
        for (_, request) in pending {
            request.continuation.resume(throwing: BridgeError.workerMessage("Cancelled"))
        }
        pending.removeAll()
    }

    func shutdown() async {
        await shutdownInternal()
    }

    private func shutdownInternal() async {
        readTask?.cancel()
        readTask = nil
        stderrDrainTask?.cancel()
        stderrDrainTask = nil
        shuttingDown = true
        if process?.isRunning == true, isReady {
            _ = try? await send(["command": "shutdown"], awaitFinalResult: false)
        }
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        stdinHandle = nil
        isReady = false
        for (_, request) in pending {
            request.continuation.resume(throwing: BridgeError.workerNotRunning)
        }
        pending.removeAll()
    }

    private func appendStderr(_ chunk: Data) {
        stderrLineBuffer.append(chunk)
        while let newlineIndex = stderrLineBuffer.firstIndex(of: 0x0A) {
            let lineData = stderrLineBuffer[..<newlineIndex]
            stderrLineBuffer.removeSubrange(...newlineIndex)
            guard let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !line.isEmpty else { continue }
            onStderrLine?(line)
        }
    }

    private func appendStdout(_ chunk: Data) {
        lineBuffer.append(chunk)
        while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer[..<newlineIndex]
            lineBuffer.removeSubrange(...newlineIndex)
            guard let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty else { continue }
            handleLine(line)
        }
    }

    private func handleLine(_ line: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
              let message = object as? [String: Any] else { return }

        let type = message["type"] as? String ?? ""
        if type == "ready" {
            isReady = true
            return
        }
        let jobID = message["job_id"] as? String ?? ""

        if type == "progress" {
            if !jobID.isEmpty, let request = pending[jobID] {
                Self.deliverProgress(message, handler: request.onProgress)
                return
            }
            // ``emit_mflux_progress`` / diffusers workers omit job_id; route to active generate requests.
            for request in pending.values where request.onProgress != nil {
                Self.deliverProgress(message, handler: request.onProgress)
            }
            return
        }

        guard !jobID.isEmpty, let request = pending[jobID] else { return }

        if type == "error" {
            pending.removeValue(forKey: jobID)
            let text = message["message"] as? String ?? "Worker error"
            request.continuation.resume(throwing: BridgeError.workerMessage(text))
            return
        }
        if type == "result" {
            if request.awaitFinalResult, message["started"] as? Bool == true {
                return
            }
            pending.removeValue(forKey: jobID)
            request.continuation.resume(returning: message)
        }
    }

    /// Progress arrives on the stdout reader task; UI updates must run on the main actor.
    private nonisolated static func deliverProgress(
        _ message: [String: Any],
        handler: ProgressHandler?
    ) {
        guard let handler else { return }
        Task { @MainActor in
            handler(message)
        }
    }
}
