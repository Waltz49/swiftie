import Foundation

/// Headless CLIP text search via `workers/clip_search_worker.py`.
@Observable
@MainActor
final class CLIPSearchBridge {
    private var bridge: JSONLineProcessBridge?
    private let environment: PythonLocator.Environment?

    private(set) var isReady = false
    private(set) var isBusy = false
    private(set) var lastError = ""
    private(set) var progress: (current: Int, total: Int, stage: String)?

    var onFinished: (([String]) -> Void)?
    var onError: ((String) -> Void)?
    var onProgress: ((Int, Int, String) -> Void)?

    private var activeJobID = ""
    private var pendingCommand: [String: Any]?

    init(profilePath: String?) {
        environment = PythonLocator.resolve(profilePath: profilePath)
    }

    var isAvailable: Bool {
        guard let environment else { return false }
        let workerPath = environment.repoRoot
            .appendingPathComponent("workers/clip_search_worker.py")
        return FileManager.default.fileExists(atPath: workerPath.path)
    }

    func search(
        textPrompt: String,
        candidatePaths: [String],
        threshold: Double,
        filterBelowThreshold: Bool = false
    ) throws {
        guard !isBusy else { throw BridgeError.busy }
        guard let environment else { throw BridgeError.pythonUnavailable }
        let prompt = textPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !candidatePaths.isEmpty else {
            throw BridgeError.encodingFailed
        }

        let jobID = UUID().uuidString
        activeJobID = jobID
        isBusy = true
        lastError = ""
        progress = nil

        let cmd: [String: Any] = [
            "command": "search",
            "job_id": jobID,
            "text_prompt": prompt,
            "candidate_paths": candidatePaths,
            "threshold": threshold,
            "filter_below_threshold": filterBelowThreshold,
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
        progress = nil
    }

    func shutdown() {
        try? bridge?.send(["command": "shutdown"])
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
        try processBridge.start(module: "workers.clip_search_worker")
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
                pendingCommand = nil
            }
        case "progress":
            let current = message["current"] as? Int ?? 0
            let total = message["total"] as? Int ?? 0
            let stage = message["stage"] as? String ?? ""
            progress = (current, total, stage)
            onProgress?(current, total, stage)
        case "result":
            let paths = message["paths"] as? [String] ?? []
            onFinished?(paths)
            isBusy = false
            activeJobID = ""
            progress = nil
        case "error":
            let error = message["message"] as? String ?? "CLIP search failed."
            lastError = error
            onError?(error)
            isBusy = false
            activeJobID = ""
            progress = nil
        default:
            break
        }
    }
}
