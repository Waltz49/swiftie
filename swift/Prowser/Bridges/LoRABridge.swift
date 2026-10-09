import Foundation

struct LoRAChoice: Identifiable, Equatable {
    var presetID: String
    var label: String
    var id: String { presetID }
}

struct LoRAPluginChoices: Equatable {
    var unsupported: Bool
    var unsupportedLabel: String
    var stackMode: Bool
    var popupMode: Bool
    var choices: [LoRAChoice]
    var selectedIDs: [String]
    var scalesByID: [String: Double]
    /// When no LoRAs are selectable in the run dialog (only implicit none).
    var emptySelectionHint: String?

    var selectableChoices: [LoRAChoice] {
        choices.filter { $0.presetID != "none" }
    }

    static func unsupported(label: String = "Not available") -> LoRAPluginChoices {
        LoRAPluginChoices(
            unsupported: true,
            unsupportedLabel: label,
            stackMode: true,
            popupMode: false,
            choices: [],
            selectedIDs: [],
            scalesByID: [:],
            emptySelectionHint: nil
        )
    }
}

struct LoRASettingsModel: Identifiable, Equatable {
    var modelKey: String
    var displayName: String
    var availableInLabel: String
    var id: String { modelKey }
}

struct LoRACatalogEntry: Identifiable, Equatable {
    var loraID: String
    var displayName: String
    var label: String
    var hostID: String
    var scale: Double
    var bestGuess: Double
    var triggerWord: String
    var comment: String
    var referencePrompt: String
    var repoID: String
    var filename: String
    var localPath: String
    var sourcePath: String
    var installed: Bool
    var lifecycle: String
    var statusLabel: String
    var hasRecoverySource: Bool
    var id: String { loraID }

    static func fromDictionary(_ dict: [String: Any]) -> LoRACatalogEntry? {
        guard let loraID = dict["lora_id"] as? String, !loraID.isEmpty else { return nil }
        return LoRACatalogEntry(
            loraID: loraID,
            displayName: dict["display_name"] as? String ?? loraID,
            label: dict["label"] as? String ?? loraID,
            hostID: dict["host_id"] as? String ?? "",
            scale: (dict["scale"] as? NSNumber)?.doubleValue ?? (dict["scale"] as? Double) ?? 1,
            bestGuess: (dict["best_guess"] as? NSNumber)?.doubleValue ?? (dict["best_guess"] as? Double) ?? 1,
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

struct LoRAModelDraftSlice: Equatable {
    var enabledIDs: [String]
    var deletedIDs: [String]
}

struct CheckLorasInstalledModel: Equatable, Identifiable {
    var modelKey: String
    var displayName: String
    var id: String { modelKey }
}

struct CheckLorasProbeChoice: Equatable, Identifiable {
    var key: String
    var label: String
    var displayName: String
    var fromDownloads: Bool
    var id: String { key }

    static func fromDictionary(_ dict: [String: Any]) -> CheckLorasProbeChoice? {
        guard let key = dict["key"] as? String, !key.isEmpty else { return nil }
        return CheckLorasProbeChoice(
            key: key,
            label: dict["label"] as? String ?? key,
            displayName: dict["display_name"] as? String ?? dict["label"] as? String ?? key,
            fromDownloads: dict["from_downloads"] as? Bool ?? false
        )
    }
}

struct CheckLorasOptions: Equatable {
    static let modelScopeAll = "all"
    static let modelScopeSelected = "selected"
    static let loraScopeAll = "all"
    static let loraScopeSelected = "selected"
    static let registrationIgnorePrevious = "ignore_previous"
    static let registrationSkipRegistered = "skip_registered"
    static let registrationOnlyRegistered = "only_registered"

    var modelScope: String
    var selectedModelKeys: [String]
    var loraScope: String
    var selectedLoraKeys: [String]
    var registrationMode: String
    var probePrompt: String
    var skipUnchanged: Bool
    var checkCrossFamilies: Bool

    static func fromDictionary(_ dict: [String: Any]) -> CheckLorasOptions {
        CheckLorasOptions(
            modelScope: dict["model_scope"] as? String ?? modelScopeAll,
            selectedModelKeys: dict["selected_model_keys"] as? [String] ?? [],
            loraScope: dict["lora_scope"] as? String ?? loraScopeAll,
            selectedLoraKeys: dict["selected_lora_keys"] as? [String] ?? [],
            registrationMode: dict["registration_mode"] as? String ?? registrationIgnorePrevious,
            probePrompt: dict["probe_prompt"] as? String ?? "test",
            skipUnchanged: dict["skip_unchanged"] as? Bool ?? true,
            checkCrossFamilies: dict["check_cross_families"] as? Bool ?? true
        )
    }

    func bridgeDictionary() -> [String: Any] {
        [
            "model_scope": modelScope,
            "selected_model_keys": selectedModelKeys,
            "lora_scope": loraScope,
            "selected_lora_keys": selectedLoraKeys,
            "registration_mode": registrationMode,
            "probe_prompt": probePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "test"
                : probePrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            "skip_unchanged": skipUnchanged,
            "check_cross_families": checkCrossFamilies,
        ]
    }
}

struct CheckLorasPrescanResult: Equatable {
    var choices: [CheckLorasProbeChoice]
    var installedModels: [CheckLorasInstalledModel]
    var savedOptions: CheckLorasOptions
}

struct CheckLorasPrepareResult: Equatable {
    var success: Bool
    var nothingToProbe: Bool
    var message: String?
}

struct CheckLorasRunResult: Equatable {
    var cancelled: Bool
    var probesDone: Int
    var resultsText: String
    var reportPaths: [String]
}

/// LoRA catalog bridge via bundled ``imagegen_plugins.lora_bridge`` worker.
@MainActor
final class LoRABridge {
    private weak var config: AppConfig?
    private let worker = PythonNDJSONWorker(module: "imagegen_plugins.lora_bridge")

    init(config: AppConfig?) {
        self.config = config
    }

    func bind(config: AppConfig) {
        self.config = config
    }

    var isAvailable: Bool {
        guard BundleCapabilities.imageGenUIEnabled else { return false }
        guard ImageGenPythonBundle.rootURL() != nil else { return false }
        guard let config else { return false }
        return ImageGenPluginAvailability.venvPythonReady(config: config)
    }

    func shutdown() {
        Task { await worker.shutdown() }
    }

    private func prepareWorker() async throws {
        guard let config else { throw BridgeError.pythonUnavailable }
        guard let env = PythonLocator.resolve(profilePath: nil, config: config) else {
            throw BridgeError.pythonUnavailable
        }
        await worker.bind(environment: env)
    }

    private func request(
        _ command: [String: Any],
        awaitFinalResult: Bool = false,
        onProgress: PythonNDJSONWorker.ProgressHandler? = nil
    ) async throws -> [String: Any] {
        try await prepareWorker()
        return try await worker.send(command, awaitFinalResult: awaitFinalResult, onProgress: onProgress)
    }

    func settingsModels() async throws -> [LoRASettingsModel] {
        let result = try await request(["command": "settings_models"])
        let raw = result["models"] as? [[String: Any]] ?? []
        return raw.compactMap { dict in
            guard let key = dict["model_key"] as? String else { return nil }
            return LoRASettingsModel(
                modelKey: key,
                displayName: dict["display_name"] as? String ?? key,
                availableInLabel: dict["available_in_label"] as? String ?? ""
            )
        }
    }

    func settingsEntries(
        modelKey: String,
        hideUninstalled: Bool,
        draftByModel: [String: LoRAModelDraftSlice]
    ) async throws -> (entries: [LoRACatalogEntry], enabledIDs: [String], deletedIDs: [String]) {
        let drafts = draftByModel.mapValues { slice in
            [
                "enabled_ids": slice.enabledIDs,
                "deleted_ids": slice.deletedIDs,
            ] as [String: Any]
        }
        let result = try await request([
            "command": "settings_entries",
            "model_key": modelKey,
            "hide_uninstalled": hideUninstalled,
            "draft_by_model": drafts,
        ])
        let entries = (result["entries"] as? [[String: Any]] ?? []).compactMap(LoRACatalogEntry.fromDictionary)
        let enabled = result["enabled_ids"] as? [String] ?? []
        let deleted = result["deleted_ids"] as? [String] ?? []
        return (entries, enabled, deleted)
    }

    func saveCatalogState(modelKey: String, byModel: [String: LoRAModelDraftSlice]) async throws {
        let normalized = byModel.mapValues { slice in
            [
                "enabled_ids": slice.enabledIDs,
                "deleted_ids": slice.deletedIDs,
            ] as [String: Any]
        }
        _ = try await request([
            "command": "save_catalog_state",
            "model_key": modelKey,
            "by_model": normalized,
        ])
    }

    func choicesForPlugin(pluginID: String, values: [String: Any]) async throws -> LoRAPluginChoices {
        var cmd: [String: Any] = [
            "command": "choices_for_plugin",
            "plugin_id": pluginID,
        ]
        if let stack = values["mflux_lora_stack"] as? [Any] {
            cmd["current_stack"] = stack
        } else if let single = values["mflux_lora"] {
            cmd["current_preset_id"] = single
        }
        if let scales = values["mflux_lora_scales_by_id"] as? [String: Any] {
            cmd["scale_overrides"] = scales
        }
        let result = try await request(cmd)
        if result["unsupported"] as? Bool == true {
            return LoRAPluginChoices.unsupported(
                label: result["unsupported_label"] as? String ?? "LoRA not supported"
            )
        }
        let choices = (result["choices"] as? [[String: Any]] ?? []).compactMap { dict -> LoRAChoice? in
            guard let id = dict["preset_id"] as? String else { return nil }
            return LoRAChoice(presetID: id, label: dict["label"] as? String ?? id)
        }
        var scales: [String: Double] = [:]
        if let raw = result["scales_by_id"] as? [String: Any] {
            for (key, value) in raw {
                if let n = value as? NSNumber {
                    scales[key] = n.doubleValue
                } else if let d = value as? Double {
                    scales[key] = d
                }
            }
        }
        let selectable = choices.filter { $0.presetID != "none" }
        let emptyHint = result["empty_selection_hint"] as? String
        return LoRAPluginChoices(
            unsupported: false,
            unsupportedLabel: "",
            stackMode: result["stack_mode"] as? Bool ?? true,
            popupMode: result["popup_mode"] as? Bool ?? false,
            choices: choices,
            selectedIDs: result["selected_ids"] as? [String] ?? [],
            scalesByID: scales,
            emptySelectionHint: emptyHint
                ?? (selectable.isEmpty
                    ? "No LoRAs available. Enable and download in Settings → LoRA."
                    : nil)
        )
    }

    func selectedDisplayText(pluginID: String, selectedIDs: [String], scalesByID: [String: Double]) async throws -> String {
        let result = try await request([
            "command": "selected_display_text",
            "plugin_id": pluginID,
            "selected_ids": selectedIDs,
            "scales_by_id": scalesByID,
        ])
        return result["text"] as? String ?? ""
    }

    func updateEntryScales(pluginID: String, scalesByID: [String: Double]) async throws {
        _ = try await request([
            "command": "update_entry_scales",
            "plugin_id": pluginID,
            "scales_by_id": scalesByID,
        ])
    }

    func exifLabelFromValues(pluginID: String, values: [String: Any]) async throws -> String? {
        let result = try await request([
            "command": "exif_label_from_values",
            "plugin_id": pluginID,
            "values": values,
        ])
        let text = (result["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    func matchExif(pluginID: String, exifLoraName: String) async throws -> [String: Any]? {
        let result = try await request([
            "command": "match_exif",
            "plugin_id": pluginID,
            "lora_text": exifLoraName,
        ])
        let ids = result["ids"] as? [String] ?? []
        if ids.isEmpty { return nil }
        var out: [String: Any] = ["ids": ids]
        if let scales = result["scales_by_id"] as? [String: Any] {
            out["scales_by_id"] = scales
        }
        return out
    }

    func getEntry(loraID: String, modelKey: String) async throws -> LoRACatalogEntry? {
        let result = try await request([
            "command": "get_entry",
            "lora_id": loraID,
            "model_key": modelKey,
        ])
        guard let dict = result["entry"] as? [String: Any] else { return nil }
        return LoRACatalogEntry.fromDictionary(dict)
    }

    func validateSource(path: String, modelKey: String) async throws -> [String: Any] {
        try await request([
            "command": "validate_source",
            "path": path,
            "model_key": modelKey,
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
        _ = try await request([
            "command": "save_metadata",
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

    func importLora(
        payload: [String: Any],
        onProgress: @escaping @Sendable (String, Int, Int) -> Void
    ) async throws -> [String: Any] {
        var cmd = payload
        cmd["command"] = "import_lora"
        return try await request(cmd, awaitFinalResult: true) { message in
            let activity = message["activity"] as? String ?? ""
            let step = (message["step"] as? NSNumber)?.intValue ?? 0
            let maximum = (message["maximum"] as? NSNumber)?.intValue ?? 1
            onProgress(activity, step, maximum)
        }
    }

    func cancelImport() async throws {
        _ = try await request(["command": "cancel_import"])
    }

    func install(loraID: String, modelKey: String) async throws {
        _ = try await request([
            "command": "install",
            "lora_id": loraID,
            "model_key": modelKey,
        ])
    }

    func delete(loraID: String, modelKey: String) async throws {
        _ = try await request([
            "command": "delete",
            "lora_id": loraID,
            "model_key": modelKey,
        ])
    }

    func findChoices() async throws -> [[String: Any]] {
        let result = try await request(["command": "find_choices"])
        return result["choices"] as? [[String: Any]] ?? []
    }

    func findOrigin(loraID: String) async throws -> [String: Any] {
        try await request([
            "command": "find_origin",
            "lora_id": loraID,
        ], awaitFinalResult: true)
    }

    func saveUserPreset() async throws {
        _ = try await request(["command": "save_user_preset"])
    }

    func applyUserPreset() async throws {
        _ = try await request(["command": "apply_user_preset"])
    }

    func restoreRecommendations(modelKey: String) async throws {
        _ = try await request([
            "command": "restore_recommendations",
            "model_key": modelKey,
        ])
    }

    func checkLorasPrescan() async throws -> CheckLorasPrescanResult {
        let result = try await request(["command": "check_loras_prescan"])
        let choices = (result["choices"] as? [[String: Any]] ?? []).compactMap(CheckLorasProbeChoice.fromDictionary)
        let installed = (result["installed_models"] as? [[String: Any]] ?? []).compactMap { dict -> CheckLorasInstalledModel? in
            guard let key = dict["model_key"] as? String else { return nil }
            return CheckLorasInstalledModel(
                modelKey: key,
                displayName: dict["display_name"] as? String ?? key
            )
        }
        let saved = CheckLorasOptions.fromDictionary(result["saved_options"] as? [String: Any] ?? [:])
        return CheckLorasPrescanResult(choices: choices, installedModels: installed, savedOptions: saved)
    }

    func checkLorasPrepare(options: CheckLorasOptions) async throws -> CheckLorasPrepareResult {
        let result = try await request([
            "command": "check_loras_prepare",
            "options": options.bridgeDictionary(),
        ])
        return CheckLorasPrepareResult(
            success: result["success"] as? Bool ?? false,
            nothingToProbe: result["nothing_to_probe"] as? Bool ?? false,
            message: result["message"] as? String
        )
    }

    func checkLorasRun(
        options: CheckLorasOptions,
        onProgress: @escaping @Sendable ([String: Any]) -> Void
    ) async throws -> CheckLorasRunResult {
        let result = try await request(
            [
                "command": "check_loras_run",
                "options": options.bridgeDictionary(),
            ],
            awaitFinalResult: true,
            onProgress: onProgress
        )
        return CheckLorasRunResult(
            cancelled: result["cancelled"] as? Bool ?? false,
            probesDone: (result["probes_done"] as? NSNumber)?.intValue ?? 0,
            resultsText: result["results_text"] as? String ?? "",
            reportPaths: result["report_paths"] as? [String] ?? []
        )
    }

    func checkLorasCancel() async throws {
        _ = try await request(["command": "check_loras_cancel"])
    }

    func checkLorasProbeHistoryCount() async throws -> Int {
        let result = try await request([
            "command": "check_loras_clear_probe_history",
            "dry_run": true,
        ])
        return (result["count_before"] as? NSNumber)?.intValue ?? 0
    }

    func checkLorasClearProbeHistory() async throws -> Int {
        let result = try await request(["command": "check_loras_clear_probe_history"])
        return (result["removed"] as? NSNumber)?.intValue ?? 0
    }
}
