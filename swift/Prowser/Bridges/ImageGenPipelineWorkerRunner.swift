import Foundation

/// Runs ``imagegen_plugins/pipelines/*.py`` workers (stdin JSON, stdout JSON).
enum ImageGenPipelineWorkerRunner {
    typealias ProgressHandler = @Sendable ([String: Any]) -> Void

    struct RunResult: Sendable {
        let exitStatus: Int32
        let stdoutText: String
        let stderrText: String
    }

    static func scriptURL(pipelineID: String, bundleRoot: URL) -> URL? {
        guard let script = ImageGenPipelineCatalog.workerScriptName(pipelineID: pipelineID) else {
            return nil
        }
        let url = bundleRoot
            .appendingPathComponent("imagegen_plugins/pipelines/\(script)")
        return FileManager.default.isReadableFile(atPath: url.path) ? url : nil
    }

    static func run(
        pipelineID: String,
        payload: [String: Any],
        environment: PythonLocator.Environment,
        onProcessStarted: (@Sendable @MainActor (Process) -> Void)? = nil,
        onProgress: ProgressHandler? = nil
    ) async throws -> RunResult {
        guard let script = scriptURL(pipelineID: pipelineID, bundleRoot: environment.bundleRoot) else {
            throw MfluxCLIError.processFailed("Missing Python worker for pipeline \(pipelineID)")
        }
        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        return try await Task.detached(priority: .userInitiated) { () async throws -> RunResult in
            ImageGenCommandLog.printInvocation(
                executablePath: environment.executable,
                arguments: ["-u", script.path]
            )
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: environment.executable)
            proc.arguments = ["-u", script.path]
            proc.currentDirectoryURL = environment.bundleRoot
            proc.environment = PythonLocator.processEnvironment(for: environment)

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            proc.standardInput = stdinPipe
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe

            let stderrHandle = stderrPipe.fileHandleForReading
            let stderrCollector = StderrProgressCollector(onProgress: onProgress)
            let stderrTask = Task.detached {
                while !Task.isCancelled {
                    let chunk = stderrHandle.availableData
                    if !chunk.isEmpty {
                        stderrCollector.append(chunk)
                        continue
                    }
                    if !proc.isRunning {
                        break
                    }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                let trailing = stderrHandle.readDataToEndOfFile()
                if !trailing.isEmpty {
                    stderrCollector.append(trailing)
                }
            }

            try proc.run()
            stdinPipe.fileHandleForWriting.write(jsonData)
            try stdinPipe.fileHandleForWriting.close()
            if let onProcessStarted {
                await onProcessStarted(proc)
            }
            proc.waitUntilExit()
            _ = await stderrTask.value

            let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            return RunResult(
                exitStatus: proc.terminationStatus,
                stdoutText: String(data: outData, encoding: .utf8) ?? "",
                stderrText: stderrCollector.plainText
            )
        }.value
    }

    /// Parses NDJSON progress lines from worker stderr (``emit_worker_message``).
    private final class StderrProgressCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var lineBuffer = Data()
        private var plainChunks: [Data] = []
        private let onProgress: ProgressHandler?

        init(onProgress: ProgressHandler?) {
            self.onProgress = onProgress
        }

        var plainText: String {
            lock.lock()
            defer { lock.unlock() }
            return String(data: Data(plainChunks.joined()), encoding: .utf8) ?? ""
        }

        func append(_ chunk: Data) {
            lock.lock()
            plainChunks.append(chunk)
            lineBuffer.append(chunk)
            let lines = drainCompleteLines()
            lock.unlock()
            for line in lines {
                handleProgressLine(line)
            }
        }

        private func drainCompleteLines() -> [String] {
            var lines: [String] = []
            while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
                let lineData = lineBuffer[..<newlineIndex]
                lineBuffer.removeSubrange(...newlineIndex)
                guard let line = String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !line.isEmpty else { continue }
                lines.append(line)
            }
            return lines
        }

        private func handleProgressLine(_ line: String) {
            guard let onProgress else { return }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let jsonText: String
            if let start = trimmed.firstIndex(of: "{"),
               let end = trimmed.lastIndex(of: "}") {
                jsonText = String(trimmed[start...end])
            } else {
                jsonText = trimmed
            }
            guard let data = jsonText.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "progress" else { return }
            Task { @MainActor in
                onProgress(object)
            }
        }
    }
}
