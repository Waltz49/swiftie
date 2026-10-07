import Foundation

/// Swift client for `imagegen_plugins/registry_bridge.py`.
@MainActor
final class ImageGenRegistryBridge {
    private var bridge: JSONLineProcessBridge?
    private let environment: PythonLocator.Environment?

    private(set) var isReady = false
    private(set) var lastError = ""

    private var pendingRequests: [String: (Result<[String: Any], Error>) -> Void] = [:]

    private weak var config: AppConfig?

    init(profilePath: String?, config: AppConfig? = nil) {
        self.config = config
        environment = PythonLocator.resolve(profilePath: profilePath, config: config)
    }

    func reloadSettings(config: AppConfig) {
        self.config = config
    }

    var isAvailable: Bool { environment != nil }

    func shutdown() {
        failPendingRequests()
        bridge?.terminate()
        bridge = nil
        isReady = false
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
        let raw = result["plugins"] as? [[String: Any]] ?? []
        return ImageGenMfluxPluginFilter.applyingMfluxAvailability(raw)
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

    struct QueueStatusBuildResult {
        var statusView: QueueJobStatusView
        var thumbnailPaths: [String]
        var fullPrompt: String
        var referencesInvalid: Bool
    }

    func buildQueueStatusView(
        pluginID: String,
        function: String,
        values: [String: Any],
        copiesTotal: Int,
        pluginUnavailable: Bool = false,
        running: Bool = false,
        omitLiveStepsRow: Bool = false,
        withAI: Bool = false,
        step: Int? = nil,
        stepTotal: Int? = nil,
        elapsedSeconds: Double? = nil,
        estimateSeconds: Double? = nil
    ) async throws -> QueueStatusBuildResult {
        var cmd: [String: Any] = [
            "command": "build_queue_status_view",
            "job_id": UUID().uuidString,
            "plugin_id": pluginID,
            "function": function,
            "values": values,
            "copies_total": copiesTotal,
            "plugin_unavailable": pluginUnavailable,
            "running": running,
            "omit_live_steps_row": omitLiveStepsRow,
            "with_ai": withAI,
        ]
        if let step { cmd["step"] = step }
        if let stepTotal { cmd["step_total"] = stepTotal }
        if let elapsedSeconds { cmd["elapsed_seconds"] = elapsedSeconds }
        if let estimateSeconds { cmd["estimate_seconds"] = estimateSeconds }
        let result = try await sendRequest(cmd)
        let viewDict = result["status_view"] as? [String: Any] ?? [:]
        return QueueStatusBuildResult(
            statusView: QueueJobStatusView.fromBridgeDictionary(viewDict),
            thumbnailPaths: result["thumbnail_paths"] as? [String] ?? [],
            fullPrompt: result["full_prompt"] as? String ?? "",
            referencesInvalid: result["references_invalid"] as? Bool ?? false
        )
    }

    func buildActiveJobStripView(
        elapsedSeconds: Double?,
        estimateSeconds: Double? = nil,
        step: Int = 0,
        stepTotal: Int = 0,
        stepsLabel: String = "Steps:",
        cooldownRemaining: Int = 0,
        completedSeries: Int? = nil,
        totalSeries: Int? = nil,
        totalQueueJobs: Int? = nil,
        includeQueueJobsRow: Bool = false
    ) async throws -> ActiveJobStripStatusView {
        var cmd: [String: Any] = [
            "command": "build_active_job_strip_view",
            "job_id": UUID().uuidString,
            "step": step,
            "step_total": stepTotal,
            "steps_label": stepsLabel,
            "cooldown_remaining": cooldownRemaining,
            "include_queue_jobs_row": includeQueueJobsRow,
        ]
        if let elapsedSeconds { cmd["elapsed_seconds"] = elapsedSeconds }
        if let estimateSeconds { cmd["estimate_seconds"] = estimateSeconds }
        if let completedSeries { cmd["completed_series"] = completedSeries }
        if let totalSeries { cmd["total_series"] = totalSeries }
        if let totalQueueJobs { cmd["total_queue_jobs"] = totalQueueJobs }
        let result = try await sendRequest(cmd)
        let viewDict = result["strip_view"] as? [String: Any] ?? [:]
        return ActiveJobStripStatusView.fromBridgeDictionary(viewDict)
    }

    struct GenerationTimingKeyResult {
        var key: GenerationTimingKey?
        var averageSeconds: Double?
    }

    func buildGenerationTimingKey(
        pluginID: String,
        values: [String: Any]
    ) async throws -> GenerationTimingKeyResult {
        let result = try await sendRequest([
            "command": "build_generation_timing_key",
            "job_id": UUID().uuidString,
            "plugin_id": pluginID,
            "values": values,
        ])
        let keyArray = result["key"] as? [Any]
        let key = keyArray.flatMap { GenerationTimingKey(bridgeArray: $0) }
        let average = result["average_seconds"] as? Double
            ?? (result["average_seconds"] as? NSNumber)?.doubleValue
        return GenerationTimingKeyResult(key: key, averageSeconds: average)
    }

    func formatGenerationExifComment(
        pluginID: String,
        values: [String: Any],
        elapsedSeconds: Double?,
        workerResult: [String: Any]
    ) async throws -> String {
        var cmd: [String: Any] = [
            "command": "format_generation_exif_comment",
            "job_id": UUID().uuidString,
            "plugin_id": pluginID,
            "values": values,
            "worker_result": workerResult,
        ]
        if let elapsedSeconds { cmd["elapsed_seconds"] = elapsedSeconds }
        let result = try await sendRequest(cmd)
        return result["comment"] as? String ?? ""
    }

    func writeGenerationExif(
        pluginID: String,
        values: [String: Any],
        outputPath: String,
        workerResult: [String: Any],
        elapsedSeconds: Double?,
        localElapsed: Double?,
        fallbackSourcePaths: [String]
    ) async throws -> Bool {
        var cmd: [String: Any] = [
            "command": "write_generation_exif",
            "job_id": UUID().uuidString,
            "plugin_id": pluginID,
            "values": values,
            "output_path": outputPath,
            "worker_result": workerResult,
            "fallback_source_paths": fallbackSourcePaths,
        ]
        if let elapsedSeconds { cmd["elapsed_seconds"] = elapsedSeconds }
        if let localElapsed { cmd["local_elapsed"] = localElapsed }
        let result = try await sendRequest(cmd)
        return result["success"] as? Bool ?? false
    }

    func repairCancelledOutputExifReferences(
        pluginID: String,
        outputPath: String,
        values: [String: Any],
        fallbackSourcePaths: [String]
    ) async throws -> Bool {
        let result = try await sendRequest([
            "command": "repair_cancelled_output_exif_references",
            "job_id": UUID().uuidString,
            "plugin_id": pluginID,
            "values": values,
            "output_path": outputPath,
            "fallback_source_paths": fallbackSourcePaths,
        ])
        return result["success"] as? Bool ?? false
    }

    func makeReadableUserCommentBeforeBrowse(
        pluginID: String,
        outputPath: String,
        values: [String: Any],
        elapsedSeconds: Double?,
        completedStep: Int,
        totalSteps: Int,
        fallbackSourcePaths: [String]
    ) async throws -> Bool {
        var cmd: [String: Any] = [
            "command": "make_readable_user_comment_before_browse",
            "job_id": UUID().uuidString,
            "plugin_id": pluginID,
            "values": values,
            "output_path": outputPath,
            "completed_step": completedStep,
            "total_steps": totalSteps,
            "fallback_source_paths": fallbackSourcePaths,
        ]
        if let elapsedSeconds { cmd["elapsed_seconds"] = elapsedSeconds }
        let result = try await sendRequest(cmd)
        return result["success"] as? Bool ?? false
    }

    func getExifUserDescription(path: String) async throws -> String? {
        let result = try await sendRequest([
            "command": "get_exif_user_description",
            "job_id": UUID().uuidString,
            "path": path,
        ])
        if result["description"] is NSNull { return nil }
        guard let description = result["description"] as? String else { return nil }
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func writeExifUserComment(path: String, comment: String) async throws -> Bool {
        let result = try await sendRequest([
            "command": "write_exif_user_comment",
            "job_id": UUID().uuidString,
            "path": path,
            "comment": comment,
        ])
        return result["success"] as? Bool ?? false
    }

    func deleteExifUserComment(path: String) async throws -> Bool {
        let result = try await sendRequest([
            "command": "delete_exif_user_comment",
            "job_id": UUID().uuidString,
            "path": path,
        ])
        return result["success"] as? Bool ?? false
    }

    func thumbnailPaths(pluginID: String, values: [String: Any]) async throws -> [String] {
        let result = try await sendRequest([
            "command": "thumbnail_paths",
            "job_id": UUID().uuidString,
            "plugin_id": pluginID,
            "values": values,
        ])
        return result["thumbnail_paths"] as? [String] ?? []
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

    private func failPendingRequests() {
        let handlers = pendingRequests
        pendingRequests.removeAll()
        for handler in handlers.values {
            handler(.failure(BridgeError.workerNotRunning))
        }
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
