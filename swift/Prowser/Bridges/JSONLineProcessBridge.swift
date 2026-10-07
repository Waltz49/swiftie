import Foundation

/// Newline-delimited JSON subprocess bridge for Python workers.
@MainActor
final class JSONLineProcessBridge {
    typealias MessageHandler = ([String: Any]) -> Void

    private let environment: PythonLocator.Environment
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = ""
    private var readSource: DispatchSourceRead?
    private var onMessage: MessageHandler?

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    init(environment: PythonLocator.Environment) {
        self.environment = environment
    }

    func setMessageHandler(_ handler: MessageHandler?) {
        onMessage = handler
    }

    func start(module: String, extraArguments: [String] = []) throws {
        try start(arguments: PythonLocator.moduleArguments(module) + extraArguments)
    }

    func start(arguments: [String]) throws {
        terminate()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: environment.executable)
        process.arguments = arguments
        process.currentDirectoryURL = environment.repoRoot

        var env = ProcessInfo.processInfo.environment
        env["PROWSER_PYTHON_ROOT"] = environment.repoRoot.path
        env["PYTHONUNBUFFERED"] = "1"
        if let profilePath = environment.profilePath, !profilePath.isEmpty {
            env["PROWSER_PROFILE"] = profilePath
        }
        process.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdoutPipe = stdout
        stderrPipe = stderr

        let source = DispatchSource.makeReadSource(fileDescriptor: stdout.fileHandleForReading.fileDescriptor, queue: .main)
        source.setEventHandler { [weak self] in
            self?.drainStdout()
        }
        source.setCancelHandler {
            stdout.fileHandleForReading.closeFile()
        }
        readSource = source

        try process.run()
        source.resume()
        self.process = process
    }

    func send(_ payload: [String: Any]) throws {
        guard let process, process.isRunning else {
            throw BridgeError.workerNotRunning
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard var line = String(data: data, encoding: .utf8) else {
            throw BridgeError.encodingFailed
        }
        line.append("\n")
        guard let stdin = process.standardInput as? Pipe else {
            throw BridgeError.workerNotRunning
        }
        stdin.fileHandleForWriting.write(line.data(using: .utf8)!)
    }

    func sendShutdown() {
        try? send(["command": "shutdown", "job_id": UUID().uuidString])
    }

    func terminate() {
        readSource?.cancel()
        readSource = nil
        if let process, process.isRunning {
            sendShutdown()
            process.terminate()
        }
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
        stdoutBuffer = ""
    }

    private func drainStdout() {
        guard let handle = stdoutPipe?.fileHandleForReading else { return }
        let chunk = handle.availableData
        guard !chunk.isEmpty else { return }
        guard let text = String(data: chunk, encoding: .utf8) else { return }
        stdoutBuffer += text
        while let range = stdoutBuffer.range(of: "\n") {
            let line = String(stdoutBuffer[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            stdoutBuffer = String(stdoutBuffer[range.upperBound...])
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            onMessage?(json)
        }
    }
}

enum BridgeError: Error, LocalizedError {
    case pythonUnavailable
    case workerNotRunning
    case encodingFailed
    case busy
    case notReady

    var errorDescription: String? {
        switch self {
        case .pythonUnavailable: return "Python worker environment not found."
        case .workerNotRunning: return "Worker process is not running."
        case .encodingFailed: return "Failed to encode bridge command."
        case .busy: return "Worker is busy."
        case .notReady: return "Worker is not ready."
        }
    }
}
