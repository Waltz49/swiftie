import Foundation

/// Long-lived stdin/stdout NDJSON worker (Python ``workers.ipc_json`` protocol).
actor PythonNDJSONWorker {
    typealias ProgressHandler = @Sendable ([String: Any]) -> Void

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

    func bind(environment: PythonLocator.Environment?) {
        if environment?.executable != self.environment?.executable
            || environment?.bundleRoot != self.environment?.bundleRoot
            || environment?.profilePath != self.environment?.profilePath {
            Task { await shutdownInternal() }
        }
        self.environment = environment
    }

    var running: Bool {
        process?.isRunning == true && isReady
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
        stderrDrainTask = Task.detached {
            while !Task.isCancelled {
                let chunk = stderr.availableData
                if chunk.isEmpty { break }
            }
        }

        try proc.run()
        try await waitForReady()
    }

    private func waitForReady() async throws {
        if isReady { return }
        for _ in 0..<300 {
            if isReady { return }
            if shuttingDown { throw BridgeError.notReady }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw BridgeError.notReady
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
        guard !jobID.isEmpty, let request = pending[jobID] else { return }

        if type == "progress" {
            request.onProgress?(message)
            return
        }
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
}
