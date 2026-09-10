import Foundation

/// Headless CNN similarity search via `workers/similarity_search_worker.py`.
@Observable
@MainActor
final class SimilaritySearchBridge {
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

    var isAvailable: Bool { environment != nil }

    func search(
        referencePaths: [String],
        candidatePaths: [String],
        similarityMetric: String = "cosine"
    ) throws {
        guard !isBusy else { throw BridgeError.busy }
        guard let environment else { throw BridgeError.pythonUnavailable }
        guard !referencePaths.isEmpty, !candidatePaths.isEmpty else {
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
            "reference_paths": referencePaths,
            "candidate_paths": candidatePaths,
            "similarity_metric": similarityMetric,
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
        try processBridge.start(module: "workers.similarity_search_worker")
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
            let error = message["message"] as? String ?? "Similarity search failed."
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
