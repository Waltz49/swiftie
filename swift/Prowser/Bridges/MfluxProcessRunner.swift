import Foundation

/// Runs an MFLUX CLI subprocess off the main thread.
enum MfluxProcessRunner {
    struct Request: Sendable {
        let executableURL: URL
        let arguments: [String]
        let environment: [String: String]
    }

    struct RunResult: Sendable {
        let exitStatus: Int32
        let stderrText: String
    }

    static func run(
        _ request: Request,
        onProcessStarted: (@Sendable @MainActor (Process) -> Void)? = nil
    ) async throws -> RunResult {
        try await Task.detached(priority: .userInitiated) {
            ImageGenCommandLog.printInvocation(
                executablePath: request.executableURL.path,
                arguments: request.arguments
            )
            let proc = Process()
            proc.executableURL = request.executableURL
            proc.arguments = request.arguments
            proc.environment = request.environment
            let stderrPipe = Pipe()
            proc.standardError = stderrPipe
            if let onProcessStarted {
                await onProcessStarted(proc)
            }
            try proc.run()
            proc.waitUntilExit()
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: errData, encoding: .utf8) ?? ""
            return RunResult(exitStatus: proc.terminationStatus, stderrText: stderrText)
        }.value
    }
}
