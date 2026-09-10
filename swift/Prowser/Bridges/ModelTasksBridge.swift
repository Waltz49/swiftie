import Foundation

/// Swift port of `workers/model_tasks_controller.py` (subprocess mode).
@Observable
@MainActor
final class ModelTasksBridge {
    private var bridge: JSONLineProcessBridge?
    private let environment: PythonLocator.Environment?

    private(set) var isReady = false
    private(set) var isBusy = false
    private(set) var activeJobID = ""
    private(set) var activeKind = ""
    private(set) var lastError = ""

    var onReady: (() -> Void)?
    var onJobStarted: ((String) -> Void)?
    var onJobProcessingStarted: ((String) -> Void)?
    var onJobFinished: ((String, Bool, String) -> Void)?
    var onCaptionChunk: ((String) -> Void)?
    var onCaptionReady: ((String) -> Void)?
    var onFluxPromptChunk: ((String) -> Void)?
    var onFluxPromptReady: ((String) -> Void)?
    var onGenerateFinished: ((Bool, String, String) -> Void)?
    var onProgress: (([String: Any]) -> Void)?

    private var pendingCommand: [String: Any]?

    init(profilePath: String?) {
        environment = PythonLocator.resolve(profilePath: profilePath)
    }

    var isAvailable: Bool { environment != nil }

    func startGenerate(payload: [String: Any]) throws -> String {
        let jobID = UUID().uuidString
        let cmd: [String: Any] = [
            "command": "generate",
            "job_id": jobID,
            "payload": payload,
        ]
        try startJob(kind: "generate", jobID: jobID, command: cmd)
        return jobID
    }

    func startCaption(filePath: String, userPromptOverride: String? = nil) throws -> String {
        let jobID = UUID().uuidString
        var cmd: [String: Any] = [
            "command": "caption",
            "job_id": jobID,
            "file_path": filePath,
        ]
        if let userPromptOverride, !userPromptOverride.isEmpty {
            cmd["user_prompt_override"] = userPromptOverride
        }
        try startJob(kind: "caption", jobID: jobID, command: cmd)
        return jobID
    }

    func cancel() {
        guard isBusy else { return }
        try? bridge?.send(["command": "cancel"])
        finishJob(kind: activeKind, success: false, error: "Cancelled")
        bridge?.terminate()
        isReady = false
    }

    func shutdown() {
        bridge?.terminate()
        bridge = nil
        isReady = false
        clearJob()
    }

    private func startJob(kind: String, jobID: String, command: [String: Any]) throws {
        guard !isBusy else { throw BridgeError.busy }
        guard let environment else { throw BridgeError.pythonUnavailable }
        try ensureWorker(environment: environment)
        activeJobID = jobID
        activeKind = kind
        isBusy = true
        lastError = ""
        onJobStarted?(kind)
        if isReady {
            try bridge?.send(command)
            pendingCommand = nil
        } else {
            pendingCommand = command
        }
    }

    private func ensureWorker(environment: PythonLocator.Environment) throws {
        if bridge?.isRunning == true { return }
        let processBridge = JSONLineProcessBridge(environment: environment)
        processBridge.setMessageHandler { [weak self] message in
            Task { @MainActor in self?.handleMessage(message) }
        }
        try processBridge.start(module: "workers.model_tasks_worker")
        bridge = processBridge
        isReady = false
    }

    private func handleMessage(_ message: [String: Any]) {
        let type = message["type"] as? String ?? ""
        switch type {
        case "ready":
            isReady = true
            onReady?()
            if let pendingCommand {
                try? bridge?.send(pendingCommand)
                self.pendingCommand = nil
            }
        case "job_started":
            let command = message["command"] as? String ?? activeKind
            onJobProcessingStarted?(command)
        case "progress":
            if message["job_id"] as? String == activeJobID || activeJobID.isEmpty {
                onProgress?(message)
            }
        case "caption_chunk":
            if let text = message["text"] as? String { onCaptionChunk?(text) }
        case "flux_prompt_chunk":
            if let text = message["text"] as? String { onFluxPromptChunk?(text) }
        case "result":
            handleResult(message)
        case "error":
            let error = message["message"] as? String ?? "Task failed."
            finishJob(kind: activeKind, success: false, error: error)
        default:
            break
        }
    }

    private func handleResult(_ message: [String: Any]) {
        let kind = message["command"] as? String ?? activeKind
        switch kind {
        case "caption":
            let caption = (message["caption"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if caption.isEmpty {
                finishJob(kind: kind, success: false, error: "Empty caption.")
            } else {
                onCaptionReady?(caption)
                finishJob(kind: kind, success: true, error: "")
            }
        case "flux_prompt":
            let prompt = (message["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if prompt.isEmpty {
                finishJob(kind: kind, success: false, error: "Empty prompt.")
            } else {
                onFluxPromptReady?(prompt)
                finishJob(kind: kind, success: true, error: "")
            }
        case "generate":
            let output = message["output_path"] as? String ?? ""
            onGenerateFinished?(true, output, "")
            finishJob(kind: kind, success: true, error: "", outputPath: output)
        default:
            finishJob(kind: kind, success: false, error: "Unknown result.")
        }
    }

    private func finishJob(kind: String, success: Bool, error: String, outputPath: String = "") {
        if !success, error != "Cancelled" {
            lastError = error
        }
        onJobFinished?(kind, success, error)
        if kind == "generate" {
            onGenerateFinished?(success, outputPath, error)
        }
        clearJob()
    }

    private func clearJob() {
        activeJobID = ""
        activeKind = ""
        isBusy = false
        pendingCommand = nil
    }
}
