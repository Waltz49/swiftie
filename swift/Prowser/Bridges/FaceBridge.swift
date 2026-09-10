import Foundation

/// Swift port of headless `workers/face_worker.py`.
@Observable
@MainActor
final class FaceBridge {
    private var bridge: JSONLineProcessBridge?
    private let environment: PythonLocator.Environment?

    private(set) var isReady = false
    private(set) var isBusy = false
    private(set) var lastError = ""
    private(set) var progress: (current: Int, total: Int, path: String)?

    var onFinished: ((Int) -> Void)?
    var onError: ((String) -> Void)?

    private var activeJobID = ""
    private var pendingCommand: [String: Any]?

    init(profilePath: String?) {
        environment = PythonLocator.resolve(profilePath: profilePath)
    }

    var isAvailable: Bool { environment != nil }

    func scanDirectory(_ directory: String, maxDepth: Int = 1, imagePaths: [String]? = nil) throws {
        guard !isBusy else { throw BridgeError.busy }
        guard let environment else { throw BridgeError.pythonUnavailable }
        let jobID = UUID().uuidString
        activeJobID = jobID
        isBusy = true
        lastError = ""
        var cmd: [String: Any] = [
            "command": "scan",
            "job_id": jobID,
            "directory": directory,
            "max_depth": maxDepth,
        ]
        if let imagePaths, !imagePaths.isEmpty {
            cmd["image_paths"] = imagePaths
        }
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
        try processBridge.start(module: "workers.face_worker")
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
        case "progress":
            let current = message["current"] as? Int ?? 0
            let total = message["total"] as? Int ?? 0
            let path = message["path"] as? String ?? ""
            progress = (current, total, path)
        case "result":
            let count = message["faces_cached"] as? Int ?? 0
            onFinished?(count)
            isBusy = false
            activeJobID = ""
            progress = nil
        case "error":
            let error = message["message"] as? String ?? "Face scan failed."
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
