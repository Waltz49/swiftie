import Foundation

/// Runs ``imagegen_plugins/pipelines/*.py`` workers (stdin JSON, stdout JSON).
enum ImageGenPipelineWorkerRunner {
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
        onProcessStarted: (@Sendable @MainActor (Process) -> Void)? = nil
    ) async throws -> RunResult {
        guard let script = scriptURL(pipelineID: pipelineID, bundleRoot: environment.bundleRoot) else {
            throw MfluxCLIError.processFailed("Missing Python worker for pipeline \(pipelineID)")
        }
        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        return try await Task.detached(priority: .userInitiated) {
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

            if let onProcessStarted {
                await onProcessStarted(proc)
            }
            try proc.run()
            stdinPipe.fileHandleForWriting.write(jsonData)
            try stdinPipe.fileHandleForWriting.close()
            proc.waitUntilExit()

            let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            return RunResult(
                exitStatus: proc.terminationStatus,
                stdoutText: String(data: outData, encoding: .utf8) ?? "",
                stderrText: String(data: errData, encoding: .utf8) ?? ""
            )
        }.value
    }
}
