import Foundation

/// Swift client for `imagegen_plugins/registry_bridge.py`.
@Observable
@MainActor
final class ImageGenRegistryBridge {
    private var bridge: JSONLineProcessBridge?
    private let environment: PythonLocator.Environment?

    private(set) var isReady = false
    private(set) var lastError = ""

    private var pendingRequests: [String: (Result<[String: Any], Error>) -> Void] = [:]

    init(profilePath: String?) {
        environment = PythonLocator.resolve(profilePath: profilePath)
    }

    var isAvailable: Bool { environment != nil }

    func shutdown() {
        bridge?.terminate()
        bridge = nil
        isReady = false
        pendingRequests.removeAll()
    }

    func listPlugins(function: String? = nil, savedValues: [String: Any]? = nil) async throws -> [[String: Any]] {
        var cmd: [String: Any] = ["command": "list_plugins", "job_id": UUID().uuidString]
        if let function, !function.isEmpty {
            cmd["function"] = function
        }
        if let savedValues {
            cmd["saved_values"] = savedValues
        }
        let result = try await sendRequest(cmd)
        return result["plugins"] as? [[String: Any]] ?? []
    }

    func buildPayload(
        pluginID: String,
        values: [String: Any],
        outputPath: String,
        applyImageExit: Bool = true
    ) async throws -> [String: Any] {
        let result = try await sendRequest([
            "command": "build_payload",
            "job_id": UUID().uuidString,
            "plugin_id": pluginID,
            "values": values,
            "output_path": outputPath,
            "apply_image_exit": applyImageExit,
        ])
        guard let payload = result["payload"] as? [String: Any] else {
            throw BridgeError.encodingFailed
        }
        return payload
    }

    func normalizeValues(
        pluginID: String,
        values: [String: Any],
        mode: String = "snapshot"
    ) async throws -> [String: Any] {
        let result = try await sendRequest([
            "command": "normalize_values",
            "job_id": UUID().uuidString,
            "plugin_id": pluginID,
            "values": values,
            "mode": mode,
        ])
        guard let normalized = result["values"] as? [String: Any] else {
            throw BridgeError.encodingFailed
        }
        return normalized
    }

    func materializeSteps(
        pluginID: String,
        values: [String: Any],
        copies: Int
    ) async throws -> [[String: Any]] {
        let result = try await sendRequest([
            "command": "materialize_steps",
            "job_id": UUID().uuidString,
            "plugin_id": pluginID,
            "values": values,
            "copies": copies,
        ])
        return result["steps"] as? [[String: Any]] ?? []
    }

    private func sendRequest(_ command: [String: Any]) async throws -> [String: Any] {
        guard let environment else { throw BridgeError.pythonUnavailable }
        try ensureWorker(environment: environment)
        let jobID = command["job_id"] as? String ?? UUID().uuidString

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[jobID] = { result in
                continuation.resume(with: result)
            }
            do {
                try bridge?.send(command)
            } catch {
                pendingRequests.removeValue(forKey: jobID)
                continuation.resume(throwing: error)
            }
        }
    }

    private func ensureWorker(environment: PythonLocator.Environment) throws {
        if bridge?.isRunning == true { return }
        let processBridge = JSONLineProcessBridge(environment: environment)
        processBridge.setMessageHandler { [weak self] message in
            Task { @MainActor in self?.handleMessage(message) }
        }
        try processBridge.start(module: "imagegen_plugins.registry_bridge")
        bridge = processBridge
        isReady = false
    }

    private func handleMessage(_ message: [String: Any]) {
        let type = message["type"] as? String ?? ""
        switch type {
        case "ready":
            isReady = true
        case "result":
            let jobID = message["job_id"] as? String ?? ""
            if let handler = pendingRequests.removeValue(forKey: jobID) {
                handler(.success(message))
            }
        case "error":
            let jobID = message["job_id"] as? String ?? ""
            let errorText = message["message"] as? String ?? "Registry bridge error."
            lastError = errorText
            if let handler = pendingRequests.removeValue(forKey: jobID) {
                handler(.failure(BridgeError.workerNotRunning))
            }
        default:
            break
        }
    }
}
