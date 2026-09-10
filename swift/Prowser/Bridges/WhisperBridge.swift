import Foundation

/// Swift port of headless `workers/whisper_worker.py`.
@Observable
@MainActor
final class WhisperBridge {
    private var bridge: JSONLineProcessBridge?
    private let environment: PythonLocator.Environment?

    private(set) var isReady = false
    private(set) var isBusy = false
    private(set) var lastError = ""

    var onTranscribed: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private var activeJobID = ""
    private var pendingCommand: [String: Any]?

    init(profilePath: String?) {
        environment = PythonLocator.resolve(profilePath: profilePath)
    }

    var isAvailable: Bool { environment != nil }

    func transcribe(wavPath: String) throws {
        guard !isBusy else { throw BridgeError.busy }
        guard let environment else { throw BridgeError.pythonUnavailable }
        let jobID = UUID().uuidString
        activeJobID = jobID
        isBusy = true
        lastError = ""
        let cmd: [String: Any] = [
            "command": "transcribe",
            "job_id": jobID,
            "wav_path": wavPath,
        ]
        try ensureWorker(environment: environment)
        if isReady {
            try bridge?.send(cmd)
            pendingCommand = nil
        } else {
            pendingCommand = cmd
        }
    }

    func cancel() {
        try? bridge?.send(["command": "cancel", "job_id": activeJobID])
        isBusy = false
        activeJobID = ""
    }

    func shutdown() {
        bridge?.terminate()
        bridge = nil
        isReady = false
        isBusy = false
    }

    private func ensureWorker(environment: PythonLocator.Environment) throws {
        if bridge?.isRunning == true { return }
        let processBridge = JSONLineProcessBridge(environment: environment)
        processBridge.setMessageHandler { [weak self] message in
            Task { @MainActor in self?.handleMessage(message) }
        }
        try processBridge.start(module: "workers.whisper_worker")
        bridge = processBridge
        isReady = false
    }

    private func handleMessage(_ message: [String: Any]) {
        let type = message["type"] as? String ?? ""
        let jobID = message["job_id"] as? String ?? ""
        if !activeJobID.isEmpty, !jobID.isEmpty, jobID != activeJobID { return }

        switch type {
        case "ready":
            isReady = true
            if let command = pendingCommand {
                try? bridge?.send(command)
                self.pendingCommand = nil
            }
        case "result":
            let text = message["text"] as? String ?? ""
            onTranscribed?(text)
            isBusy = false
            activeJobID = ""
        case "error":
            let error = message["message"] as? String ?? "Transcription failed."
            lastError = error
            onError?(error)
            isBusy = false
            activeJobID = ""
        default:
            break
        }
    }
}
