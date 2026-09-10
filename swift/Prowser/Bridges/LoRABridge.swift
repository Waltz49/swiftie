import Foundation

struct LoRASettingsModel: Identifiable, Hashable {
    var id: String { modelKey }
    let modelKey: String
    let displayName: String
    let availableInLabel: String
}

struct LoRACatalogEntry: Identifiable, Hashable {
    var id: String { loraID }
    let loraID: String
    let displayName: String
    let label: String
    let choiceLabel: String
    let hostID: String
    let scale: Double
    let bestGuess: Double
    let triggerWord: String
    let comment: String
    let referencePrompt: String
    let repoID: String
    let filename: String
    let localPath: String
    let sourcePath: String
    let installed: Bool
    let lifecycle: String
    let statusLabel: String
    let hasRecoverySource: Bool

    static func fromBridgeDictionary(_ dict: [String: Any]) -> LoRACatalogEntry {
        LoRACatalogEntry(
            loraID: dict["lora_id"] as? String ?? "",
            displayName: dict["display_name"] as? String ?? "",
            label: dict["label"] as? String ?? "",
            choiceLabel: dict["choice_label"] as? String ?? "",
            hostID: dict["host_id"] as? String ?? "",
            scale: dict["scale"] as? Double ?? (dict["scale"] as? Int).map(Double.init) ?? 1.0,
            bestGuess: dict["best_guess"] as? Double ?? (dict["best_guess"] as? Int).map(Double.init) ?? 1.0,
            triggerWord: dict["trigger_word"] as? String ?? "",
            comment: dict["comment"] as? String ?? "",
            referencePrompt: dict["reference_prompt"] as? String ?? "",
            repoID: dict["repo_id"] as? String ?? "",
            filename: dict["filename"] as? String ?? "",
            localPath: dict["local_path"] as? String ?? "",
            sourcePath: dict["source_path"] as? String ?? "",
            installed: dict["installed"] as? Bool ?? false,
            lifecycle: dict["lifecycle"] as? String ?? "",
            statusLabel: dict["status_label"] as? String ?? "",
            hasRecoverySource: dict["has_recovery_source"] as? Bool ?? false
        )
    }
}

struct LoRAChoice: Identifiable, Hashable {
    var id: String { presetID }
    let label: String
    let presetID: String

    static func fromBridgeDictionary(_ dict: [String: Any]) -> LoRAChoice {
        LoRAChoice(
            label: dict["label"] as? String ?? "",
            presetID: dict["preset_id"] as? String ?? ""
        )
    }
}

struct LoRAFindChoice: Identifiable, Hashable {
    var id: String { key }
    let key: String
    let displayName: String
    let weightsPath: String
    let triggerWord: String
    let comment: String
    let repoID: String
    let filename: String
    let sourcePath: String
    let scale: Double
    let fromDownloads: Bool

    static func fromBridgeDictionary(_ dict: [String: Any]) -> LoRAFindChoice {
        LoRAFindChoice(
            key: dict["key"] as? String ?? "",
            displayName: dict["display_name"] as? String ?? "",
            weightsPath: dict["weights_path"] as? String ?? "",
            triggerWord: dict["trigger_word"] as? String ?? "",
            comment: dict["comment"] as? String ?? "",
            repoID: dict["repo_id"] as? String ?? "",
            filename: dict["filename"] as? String ?? "",
            sourcePath: dict["source_path"] as? String ?? "",
            scale: dict["scale"] as? Double ?? (dict["scale"] as? Int).map(Double.init) ?? 1.0,
            fromDownloads: dict["from_downloads"] as? Bool ?? false
        )
    }
}

struct LoRAPluginChoices: Hashable {
    let unsupported: Bool
    let unsupportedLabel: String
    let stackMode: Bool
    let popupMode: Bool
    let choices: [LoRAChoice]
    let selectedIDs: [String]
    let scalesByID: [String: Double]

    static func fromBridgeDictionary(_ dict: [String: Any]) -> LoRAPluginChoices {
        let choices = (dict["choices"] as? [[String: Any]] ?? []).map(LoRAChoice.fromBridgeDictionary)
        let selected = dict["selected_ids"] as? [String] ?? []
        let scalesRaw = dict["scales_by_id"] as? [String: Any] ?? [:]
        var scales: [String: Double] = [:]
        for (key, value) in scalesRaw {
            if let d = value as? Double {
                scales[key] = d
            } else if let i = value as? Int {
                scales[key] = Double(i)
            }
        }
        return LoRAPluginChoices(
            unsupported: dict["unsupported"] as? Bool ?? false,
            unsupportedLabel: dict["unsupported_label"] as? String ?? "not supported with this model",
            stackMode: dict["stack_mode"] as? Bool ?? false,
            popupMode: dict["popup_mode"] as? Bool ?? false,
            choices: choices,
            selectedIDs: selected,
            scalesByID: scales
        )
    }
}

struct LoRAImportProgress: Equatable {
    var activity: String
    var step: Int
    var maximum: Int
}

/// Swift client for `imagegen_plugins/lora_bridge.py`.
@Observable
@MainActor
final class LoRABridge {
    private var bridge: JSONLineProcessBridge?
    private let environment: PythonLocator.Environment?

    private(set) var isReady = false
    private(set) var lastError = ""
    private(set) var importProgress: LoRAImportProgress?
    private(set) var isImporting = false

    private var pendingRequests: [String: (Result<[String: Any], Error>) -> Void] = [:]
    private var importCompletion: ((Bool, String, LoRACatalogEntry?) -> Void)?
    private var findOriginCompletion: ((Bool, String) -> Void)?

    init(profilePath: String?) {
        environment = PythonLocator.resolve(profilePath: profilePath)
    }

    var isAvailable: Bool { environment != nil }

    func shutdown() {
        bridge?.terminate()
        bridge = nil
        isReady = false
        pendingRequests.removeAll()
        isImporting = false
        importProgress = nil
    }

    func settingsModels() async throws -> [LoRASettingsModel] {
        let result = try await sendRequest(["command": "settings_models", "job_id": UUID().uuidString])
        return (result["models"] as? [[String: Any]] ?? []).map { dict in
            LoRASettingsModel(
                modelKey: dict["model_key"] as? String ?? "",
                displayName: dict["display_name"] as? String ?? "",
                availableInLabel: dict["available_in_label"] as? String ?? ""
            )
        }
    }

    func settingsEntries(
        modelKey: String,
        hideUninstalled: Bool,
        draftByModel: [String: [String: Any]]? = nil
    ) async throws -> (entries: [LoRACatalogEntry], enabledIDs: [String], deletedIDs: [String]) {
        var cmd: [String: Any] = [
            "command": "settings_entries",
            "job_id": UUID().uuidString,
            "model_key": modelKey,
            "hide_uninstalled": hideUninstalled,
        ]
        if let draftByModel {
            cmd["draft_by_model"] = draftByModel
        }
        let result = try await sendRequest(cmd)
        let entries = (result["entries"] as? [[String: Any]] ?? []).map(LoRACatalogEntry.fromBridgeDictionary)
        return (
            entries,
            result["enabled_ids"] as? [String] ?? [],
            result["deleted_ids"] as? [String] ?? []
        )
    }

    func saveCatalogState(modelKey: String, byModel: [String: [String: Any]]) async throws {
        _ = try await sendRequest([
            "command": "save_catalog_state",
            "job_id": UUID().uuidString,
            "model_key": modelKey,
            "by_model": byModel,
        ])
    }

    func choicesForPlugin(
        pluginID: String,
        currentStack: [String],
        currentPresetID: String,
        scaleOverrides: [String: Double]
    ) async throws -> LoRAPluginChoices {
        let result = try await sendRequest([
            "command": "choices_for_plugin",
            "job_id": UUID().uuidString,
            "plugin_id": pluginID,
            "current_stack": currentStack,
            "current_preset_id": currentPresetID,
            "scale_overrides": scaleOverrides,
        ])
        return LoRAPluginChoices.fromBridgeDictionary(result)
    }

    func selectedDisplayText(
        pluginID: String,
        selectedIDs: [String],
        scalesByID: [String: Double]
    ) async throws -> String {
        let result = try await sendRequest([
            "command": "selected_display_text",
            "job_id": UUID().uuidString,
            "plugin_id": pluginID,
            "selected_ids": selectedIDs,
            "scales_by_id": scalesByID,
        ])
        return result["text"] as? String ?? ""
    }

    func updateEntryScales(_ scalesByID: [String: Double]) async throws {
        _ = try await sendRequest([
            "command": "update_entry_scales",
            "job_id": UUID().uuidString,
            "scales_by_id": scalesByID,
        ])
    }

    func install(loraID: String) async throws {
        _ = try await sendRequest([
            "command": "install",
            "job_id": UUID().uuidString,
            "lora_id": loraID,
        ])
    }

    func delete(loraID: String, modelKey: String, doUninstall: Bool) async throws {
        _ = try await sendRequest([
            "command": "delete",
            "job_id": UUID().uuidString,
            "lora_id": loraID,
            "model_key": modelKey,
            "do_uninstall": doUninstall,
        ])
    }

    func saveUserPreset() async throws {
        _ = try await sendRequest([
            "command": "save_user_preset",
            "job_id": UUID().uuidString,
        ])
    }

    func applyUserPreset() async throws -> Int {
        let result = try await sendRequest([
            "command": "apply_user_preset",
            "job_id": UUID().uuidString,
        ])
        return result["enabled_count"] as? Int ?? 0
    }

    func restoreRecommendations() async throws -> Int {
        let result = try await sendRequest([
            "command": "restore_recommendations",
            "job_id": UUID().uuidString,
        ])
        return result["enabled_count"] as? Int ?? 0
    }

    func findChoices() async throws -> [LoRAFindChoice] {
        let result = try await sendRequest([
            "command": "find_choices",
            "job_id": UUID().uuidString,
        ])
        return (result["choices"] as? [[String: Any]] ?? []).map(LoRAFindChoice.fromBridgeDictionary)
    }

    func getEntry(loraID: String, modelKey: String) async throws -> LoRACatalogEntry {
        let result = try await sendRequest([
            "command": "get_entry",
            "job_id": UUID().uuidString,
            "lora_id": loraID,
            "model_key": modelKey,
        ])
        return LoRACatalogEntry.fromBridgeDictionary(result["entry"] as? [String: Any] ?? [:])
    }

    func validateSource(modelKey: String, path: String) async throws -> [String: Any] {
        try await sendRequest([
            "command": "validate_source",
            "job_id": UUID().uuidString,
            "model_key": modelKey,
            "path": path,
        ])
    }

    func saveMetadata(
        loraID: String,
        displayName: String,
        triggerWord: String,
        bestGuess: Double,
        comment: String,
        referencePrompt: String,
        repoID: String,
        filename: String,
        sourcePath: String
    ) async throws {
        _ = try await sendRequest([
            "command": "save_metadata",
            "job_id": UUID().uuidString,
            "lora_id": loraID,
            "display_name": displayName,
            "trigger_word": triggerWord,
            "best_guess": bestGuess,
            "comment": comment,
            "reference_prompt": referencePrompt,
            "repo_id": repoID,
            "filename": filename,
            "source_path": sourcePath,
        ])
    }

    func importLoRA(
        modelKey: String,
        sourcePath: String,
        displayName: String,
        triggerWord: String,
        bestGuess: Double,
        comment: String,
        referencePrompt: String,
        reuseLoraID: String?,
        repoID: String,
        filename: String,
        recoverySourcePath: String,
        onComplete: @escaping (Bool, String, LoRACatalogEntry?) -> Void
    ) async throws {
        guard !isImporting else { throw BridgeError.busy }
        isImporting = true
        importProgress = LoRAImportProgress(activity: "Starting…", step: 0, maximum: 6)
        importCompletion = onComplete
        let jobID = UUID().uuidString
        var cmd: [String: Any] = [
            "command": "import_lora",
            "job_id": jobID,
            "model_key": modelKey,
            "source_path": sourcePath,
            "display_name": displayName,
            "trigger_word": triggerWord,
            "best_guess": bestGuess,
            "comment": comment,
            "reference_prompt": referencePrompt,
            "repo_id": repoID,
            "filename": filename,
            "recovery_source_path": recoverySourcePath,
        ]
        if let reuseLoraID, !reuseLoraID.isEmpty {
            cmd["reuse_lora_id"] = reuseLoraID
        }
        _ = try await sendRequest(cmd)
    }

    func cancelImport() async {
        _ = try? await sendRequest([
            "command": "cancel_import",
            "job_id": UUID().uuidString,
        ])
    }

    func findOrigin(loraID: String, onComplete: @escaping (Bool, String) -> Void) async throws {
        findOriginCompletion = onComplete
        _ = try await sendRequest([
            "command": "find_origin",
            "job_id": UUID().uuidString,
            "lora_id": loraID,
        ])
    }

    func matchExif(pluginID: String, loraText: String) async throws -> (ids: [String], scales: [String: Double]) {
        let result = try await sendRequest([
            "command": "match_exif",
            "job_id": UUID().uuidString,
            "plugin_id": pluginID,
            "lora_text": loraText,
        ])
        let ids = result["ids"] as? [String] ?? []
        let scalesRaw = result["scales_by_id"] as? [String: Any] ?? [:]
        var scales: [String: Double] = [:]
        for (key, value) in scalesRaw {
            if let d = value as? Double {
                scales[key] = d
            } else if let i = value as? Int {
                scales[key] = Double(i)
            }
        }
        return (ids, scales)
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
        try processBridge.start(module: "imagegen_plugins.lora_bridge")
        bridge = processBridge
        isReady = false
    }

    private func handleMessage(_ message: [String: Any]) {
        let type = message["type"] as? String ?? ""
        let jobID = message["job_id"] as? String ?? ""

        switch type {
        case "ready":
            isReady = true
        case "progress":
            if message["command"] as? String == "import_lora" {
                importProgress = LoRAImportProgress(
                    activity: message["activity"] as? String ?? "",
                    step: message["step"] as? Int ?? 0,
                    maximum: message["maximum"] as? Int ?? 1
                )
            }
        case "result":
            if message["command"] as? String == "import_lora",
               message["started"] as? Bool != true {
                isImporting = false
                importProgress = nil
                let success = message["success"] as? Bool ?? false
                let err = message["message"] as? String ?? ""
                let entryDict = message["entry"] as? [String: Any]
                let entry = entryDict.map(LoRACatalogEntry.fromBridgeDictionary)
                importCompletion?(success, err, entry)
                importCompletion = nil
                if let handler = pendingRequests.removeValue(forKey: jobID) {
                    handler(.success(message))
                }
                return
            }
            if message["command"] as? String == "find_origin",
               message["started"] as? Bool != true {
                let success = message["success"] as? Bool ?? false
                var text = message["message"] as? String ?? ""
                if success {
                    let source = (message["page_url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !source.isEmpty {
                        text = "Reinstall metadata was updated.\n\nSource: \(source)"
                    } else {
                        text = "Reinstall metadata was updated."
                    }
                }
                findOriginCompletion?(success, text)
                findOriginCompletion = nil
            }
            if let handler = pendingRequests.removeValue(forKey: jobID) {
                handler(.success(message))
            }
        case "error":
            let errorText = message["message"] as? String ?? "LoRA bridge error."
            lastError = errorText
            if isImporting {
                isImporting = false
                importProgress = nil
                importCompletion?(false, errorText, nil)
                importCompletion = nil
            }
            if let handler = pendingRequests.removeValue(forKey: jobID) {
                handler(.failure(BridgeError.workerNotRunning))
            }
        default:
            break
        }
    }
}
