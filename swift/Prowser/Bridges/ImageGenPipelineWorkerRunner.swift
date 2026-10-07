import Foundation

/// Runs ``imagegen_plugins/pipelines/*.py`` workers (stdin JSON, stdout JSON).
enum ImageGenPipelineWorkerRunner {
    struct RunResult: Sendable {
        let exitStatus: Int32
        let stdoutText: String
        let stderrText: String
    }

    static func scriptURL(pipelineID: String, repoRoot: URL) -> URL? {
        let relative: String?
        switch pipelineID {
        case "mflux_flux2_klein_create":
            relative = "imagegen_plugins/pipelines/mflux_flux2_klein_create.py"
        case "mflux_flux2_klein_edit", "mflux_flux2_klein_expand":
            relative = "imagegen_plugins/pipelines/mflux_flux2_klein_edit.py"
        default:
            relative = nil
        }
        guard let relative else { return nil }
        let url = repoRoot.appendingPathComponent(relative)
        return FileManager.default.isReadableFile(atPath: url.path) ? url : nil
    }

    static func run(
        pipelineID: String,
        payload: [String: Any],
        environment: PythonLocator.Environment,
        onProcessStarted: (@Sendable @MainActor (Process) -> Void)? = nil
    ) async throws -> RunResult {
        guard let script = scriptURL(pipelineID: pipelineID, repoRoot: environment.repoRoot) else {
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
            proc.currentDirectoryURL = environment.repoRoot
            var env = ProcessInfo.processInfo.environment
            env["PYTHONPATH"] = environment.repoRoot.path
            proc.environment = env

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
