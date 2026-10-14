import Foundation

private enum LoRAServiceTiming {
    static let workerReadyTimeout: TimeInterval = 5
}

// Types shared with UI (formerly LoRABridge.swift).
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
    var catalogScalesByID: [String: Double]
    var bestGuessByID: [String: Double]
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
            catalogScalesByID: [:],
            bestGuessByID: [:],
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
    var registered: Bool
    var probeStateForModel: String
    var id: String { loraID }

    static func fromEntry(
        _ entry: LoRAEntry,
        modelKey: String,
        lc: [String: Any],
        draftByModel: [String: LoRAModelDraftSlice]? = nil
    ) -> LoRACatalogEntry {
        let lifecycle = LoRACatalog.lifecycleState(loraID: entry.loraID, modelKey: modelKey, lc: lc, draftByModel: draftByModel)
        let weights = LoRAPathResolver.localWeightsPath(loraID: entry.loraID, entry: entry)
        let trigger = (entry.triggerWord ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var label = LoRACatalog.baseDisplayName(entry: entry, modelKey: modelKey)
        if LoRAModelRegistry.isCrossFamily(entry: entry, modelKey: modelKey) {
            label += " *"
        }
        if !trigger.isEmpty {
            let maxLen = 30
            let shown = trigger.count > maxLen ? String(trigger.prefix(maxLen - 3)) + "..." : trigger
            label = "\(label) - Trigger: \(shown)"
        }
        return LoRACatalogEntry(
            loraID: entry.loraID,
            displayName: entry.displayName,
            label: label,
            hostID: entry.hostID,
            scale: entry.scale,
            bestGuess: entry.bestGuess,
            triggerWord: trigger,
            comment: entry.comment ?? "",
            referencePrompt: entry.referencePrompt ?? "",
            repoID: entry.repoID,
            filename: entry.filename,
            localPath: entry.localPath ?? "",
            sourcePath: entry.sourcePath ?? "",
            installed: weights != nil,
            lifecycle: lifecycle,
            statusLabel: statusLabel(for: lifecycle),
            hasRecoverySource: !(entry.sourcePath ?? "").isEmpty || !entry.repoID.isEmpty,
            registered: true,
            probeStateForModel: LoRACatalog.probeStateForModel(entry: entry, modelKey: modelKey, lc: lc)
        )
    }

    private static func statusLabel(for lifecycle: String) -> String {
        switch lifecycle {
        case "active": return "active"
        case "installed": return "installed"
        case "uninstalled": return "uninstalled"
        case "deleted": return "deleted"
        default: return lifecycle
        }
    }
}

struct LoRARemovalInfo: Equatable {
    var displayName: String
    var sharedModelLabels: [String]
}

enum LoRADeleteMode: String {
    case unregister
    case deleteWeights = "delete_weights"
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
    static let defaultProbePrompt = "A woman riding a bicycle on a path."

    static func normalizedProbePrompt(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultProbePrompt : trimmed
    }

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
            probePrompt: normalizedProbePrompt(dict["probe_prompt"] as? String ?? ""),
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
            "probe_prompt": Self.normalizedProbePrompt(probePrompt),
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
    var cancelled: Bool
    var nothingToProbe: Bool
    var message: String?
}

struct CheckLorasRunResult: Equatable {
    var cancelled: Bool
    var probesDone: Int
    var resultsText: String
    var reportPaths: [String]
}

/// Native LoRA catalog + settings; Python subprocess only for import / Check LoRAs probes.
@MainActor
final class LoRAService {
    private weak var config: AppConfig?
    private var catalogStore: LoRACatalogStore?
    private let opsWorker = PythonNDJSONWorker(module: "imagegen_plugins.lora_ops_worker")

    init(config: AppConfig?) {
        self.config = config
        if let config {
            catalogStore = LoRACatalogStore(paths: config.profilePaths)
        }
    }

    func bind(config: AppConfig) {
        self.config = config
        catalogStore = LoRACatalogStore(paths: config.profilePaths)
    }

    var isAvailable: Bool {
        guard BundleCapabilities.imageGenUIEnabled else { return false }
        return config != nil
    }

    var pythonOpsAvailable: Bool {
        guard let config else { return false }
        return ImageGenPythonBundle.rootURL() != nil
            && ImageGenPluginAvailability.venvPythonReady(config: config)
    }

    static let workerReadyTimeout: TimeInterval = LoRAServiceTiming.workerReadyTimeout

    func waitUntilAvailable(timeout: TimeInterval = LoRAServiceTiming.workerReadyTimeout) async -> Bool {
        if isAvailable { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if isAvailable { return true }
        }
        return isAvailable
    }

    func shutdown() {
        Task { await opsWorker.shutdown() }
    }

    private func store() throws -> LoRACatalogStore {
        guard let catalogStore else { throw BridgeError.workerMessage("LoRA catalog is not configured.") }
        return catalogStore
    }

    private var didAttemptPythonCatalogMigration = false

    /// Runs Python ``migrate_lora_catalog`` once when the on-disk file predates disk-first schema.
    func ensureCatalogMigrated() async throws {
        let store = try store()
        let lc = store.load()
        guard LoRACatalogSettings.needsPythonDiskFirstMigration(lc) else { return }
        guard pythonOpsAvailable else { return }
        guard !didAttemptPythonCatalogMigration else { return }
        didAttemptPythonCatalogMigration = true
        _ = try await opsRequest(["command": "migrate_catalog"])
        store.invalidateCache()
    }

    private func loadCatalog() async throws -> [String: Any] {
        try await ensureCatalogMigrated()
        return try store().load()
    }

    private func ensureOpsWorker() async throws {
        guard pythonOpsAvailable, let config else { throw BridgeError.pythonUnavailable }
        guard let env = PythonLocator.resolve(profilePath: nil, config: config) else {
            throw BridgeError.pythonUnavailable
        }
        await opsWorker.bind(environment: env)
    }

    private func opsRequest(
        _ command: [String: Any],
        awaitFinalResult: Bool = false,
        onProgress: PythonNDJSONWorker.ProgressHandler? = nil
    ) async throws -> [String: Any] {
        try await ensureOpsWorker()
        return try await opsWorker.send(command, awaitFinalResult: awaitFinalResult, onProgress: onProgress)
    }

    func settingsModels() async throws -> [LoRASettingsModel] {
        return LoRAModelRegistry.modelsForSettings().map {
            LoRASettingsModel(
                modelKey: $0.modelKey,
                displayName: $0.displayName.split(separator: "/").last.map(String.init) ?? $0.displayName,
                availableInLabel: LoRAModelRegistry.availableInLabel(modelKey: $0.modelKey)
            )
        }
    }

    func settingsEntries(
        modelKey: String,
        hideUninstalled: Bool,
        draftByModel: [String: LoRAModelDraftSlice]
    ) async throws -> (
        entries: [LoRACatalogEntry],
        discoveredEntries: [LoRACatalogEntry],
        enabledIDs: [String],
        deletedIDs: [String]
    ) {
        let lc = try await loadCatalog()
        let slice = modelSlice(modelKey: modelKey, lc: lc, draftByModel: draftByModel)
        let entries = LoRACatalog.settingsEntries(lc: lc, modelKey: modelKey, draftByModel: draftByModel)
            .map { LoRACatalogEntry.fromEntry($0, modelKey: modelKey, lc: lc, draftByModel: draftByModel) }
            .filter { !hideUninstalled || $0.lifecycle != "uninstalled" }
        let profilePaths = config?.profilePaths ?? ProfilePaths(profilePath: nil)
        let discovered = await Task.detached(priority: .utility) {
            Self.discoverDiskEntries(lc: lc, savedPaths: entries, profilePaths: profilePaths)
        }.value
        return (entries, discovered, slice.enabledIDs, slice.deletedIDs)
    }

    private func modelSlice(
        modelKey: String,
        lc: [String: Any],
        draftByModel: [String: LoRAModelDraftSlice]
    ) -> LoRACatalogSettings.ModelSlice {
        if let draft = draftByModel[modelKey] {
            return LoRACatalogSettings.ModelSlice(
                enabledIDs: draft.enabledIDs,
                deletedIDs: draft.deletedIDs
            )
        }
        return LoRACatalogSettings.modelState(lc: lc, modelKey: modelKey)
    }

    func saveCatalogState(modelKey: String, byModel: [String: LoRAModelDraftSlice]) async throws {
        let store = try store()
        LoRACatalogPersistence.saveCatalogState(byModel: byModel, store: store)
        if !modelKey.isEmpty, let config {
            config.setImagegenLoraModelKey(modelKey)
        }
    }

    func choicesForPlugin(pluginID: String, values: [String: Any]) async throws -> LoRAPluginChoices {
        guard let plugin = ImageGenPluginCatalog.plugin(pluginID: pluginID) else {
            return LoRAPluginChoices.unsupported(label: "LoRA not supported")
        }
        guard plugin.loraHostID != nil else {
            return LoRAPluginChoices.unsupported(label: "LoRA not supported with this model")
        }
        let lc = try await loadCatalog()
        let pairs = LoRACatalog.choicesForPlugin(plugin: plugin, lc: lc)
        let choices = pairs.map { LoRAChoice(presetID: $0.id, label: $0.label) }
        let selected = LoRAJobSnapshot.effectiveLoraIDs(from: values, pipelineID: plugin.pipelineID)
        let scales = Self.doubleMap(from: values["mflux_lora_scales_by_id"])
        var catalogScales: [String: Double] = [:]
        var bestGuess: [String: Double] = [:]
        for choice in choices where choice.presetID != "none" {
            if let entry = LoRACatalog.getEntry(loraID: choice.presetID, lc: lc) {
                catalogScales[choice.presetID] = entry.scale
                bestGuess[choice.presetID] = entry.bestGuess
            }
        }
        let selectable = choices.filter { $0.presetID != "none" }
        let hostID = plugin.loraHostID
        let stackMode = hostID != nil && hostID != LoRAHostRegistry.sd15
        let popupMode = hostID != nil
        return LoRAPluginChoices(
            unsupported: false,
            unsupportedLabel: "",
            stackMode: stackMode,
            popupMode: popupMode,
            choices: choices,
            selectedIDs: selected,
            scalesByID: scales,
            catalogScalesByID: catalogScales,
            bestGuessByID: bestGuess,
            emptySelectionHint: selectable.isEmpty
                ? "No LoRAs in the Create menu. Add LoRA files and run Test LoRAs in Settings → LoRA."
                : nil
        )
    }

    func selectedDisplayText(pluginID: String, selectedIDs: [String], scalesByID: [String: Double]) async throws -> String {
        let lc = try await loadCatalog()
        let names: [String] = selectedIDs.compactMap { id in
            guard id != "none", let entry = LoRACatalog.getEntry(loraID: id, lc: lc) else { return nil }
            let scale = scalesByID[id] ?? entry.scale
            return "\(entry.displayName) (\(scale))"
        }
        return names.joined(separator: " + ")
    }

    func updateEntryScales(pluginID: String, scalesByID: [String: Double]) async throws {
        let store = try store()
        var lc = try await loadCatalog()
        var overrides = LoRACatalogSettings.entryOverrides(from: lc)
        for (lid, scale) in scalesByID {
            var slice = overrides[lid] ?? [:]
            slice["scale"] = scale
            overrides[lid] = slice
        }
        lc[LoRACatalogSettings.entryOverridesKey] = overrides
        store.save(lc)
    }

    func exifLabelFromValues(pluginID: String, values: [String: Any]) async throws -> String? {
        guard let plugin = ImageGenPluginCatalog.plugin(pluginID: pluginID) else { return nil }
        let ids = LoRAJobSnapshot.effectiveLoraIDs(from: values, pipelineID: plugin.pipelineID)
        if ids.isEmpty {
            return ImageGenExifCommentFormatting.loraNameForExifFromValues(
                values: values,
                pipelineID: plugin.pipelineID,
                loraHostID: plugin.loraHostID
            )
        }
        let lc = try await loadCatalog()
        var labels: [String] = []
        for (index, loraID) in ids.enumerated() {
            let name = LoRACatalog.getEntry(loraID: loraID, lc: lc)?.displayName ?? loraID
            let scale = ImageGenExifCommentFormatting.loraScaleForExif(
                values: values,
                presetID: loraID,
                index: index
            )
            labels.append("\(name) [\(ImageGenExifCommentFormatting.formatExifLoraWeight(scale))]")
        }
        if labels.isEmpty { return nil }
        if labels.count == 1 { return labels[0] }
        return labels.joined(separator: " + ")
    }

    func matchExif(pluginID: String, exifLoraName: String) async throws -> [String: Any]? {
        guard let plugin = ImageGenPluginCatalog.plugin(pluginID: pluginID) else { return nil }
        let lc = try await loadCatalog()
        let (ids, scales) = LoRAExifMatch.match(loraText: exifLoraName, plugin: plugin, lc: lc)
        if ids.isEmpty { return nil }
        var out: [String: Any] = ["ids": ids]
        if !scales.isEmpty { out["scales_by_id"] = scales }
        return out
    }

    func getEntry(loraID: String, modelKey: String) async throws -> LoRACatalogEntry? {
        let lc = try await loadCatalog()
        guard let entry = LoRACatalog.getEntry(loraID: loraID, lc: lc) else { return nil }
        return LoRACatalogEntry.fromEntry(entry, modelKey: modelKey, lc: lc)
    }

    func validateSource(path: String, modelKey: String) async throws -> [String: Any] {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return ["valid": false, "message": "File is not readable."]
        }
        guard url.pathExtension.lowercased() == "safetensors" else {
            return ["valid": false, "message": "Expected a .safetensors file."]
        }
        return ["valid": true, "path": url.path]
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
        let store = try store()
        var lc = try await loadCatalog()
        guard let raw = (lc[LoRACatalogSettings.userEntriesKey] as? [String: Any])?[loraID] as? [String: Any],
              var entry = LoRAEntry.fromDictionary(raw) else { return }
        entry.displayName = displayName
        entry.triggerWord = triggerWord.isEmpty ? nil : triggerWord
        entry.bestGuess = bestGuess
        entry.comment = comment.isEmpty ? nil : comment
        entry.referencePrompt = referencePrompt.isEmpty ? nil : referencePrompt
        entry.repoID = repoID
        entry.filename = filename
        entry.sourcePath = sourcePath.isEmpty ? nil : sourcePath
        var users = lc[LoRACatalogSettings.userEntriesKey] as? [String: Any] ?? [:]
        users[loraID] = entry.toDictionary()
        lc[LoRACatalogSettings.userEntriesKey] = users
        store.save(lc)
    }

    func importLora(
        payload: [String: Any],
        onProgress: @escaping @Sendable (String, Int, Int) -> Void
    ) async throws -> [String: Any] {
        var cmd = payload
        cmd["command"] = "import_lora"
        let result = try await opsRequest(cmd, awaitFinalResult: true) { message in
            let activity = message["activity"] as? String ?? ""
            let step = (message["step"] as? NSNumber)?.intValue ?? 0
            let maximum = (message["maximum"] as? NSNumber)?.intValue ?? 1
            onProgress(activity, step, maximum)
        }
        catalogStore?.invalidateCache()
        return result
    }

    func cancelImport() async throws {
        _ = try await opsRequest(["command": "cancel_import"])
    }

    func install(loraID: String, modelKey: String) async throws {
        _ = modelKey
        _ = try await opsRequest([
            "command": "install",
            "lora_id": loraID,
        ])
        catalogStore?.invalidateCache()
    }

    func loraRemovalInfo(loraID: String) async throws -> LoRARemovalInfo {
        let result = try await opsRequest([
            "command": "lora_removal_info",
            "lora_id": loraID,
        ])
        return LoRARemovalInfo(
            displayName: result["display_name"] as? String ?? loraID,
            sharedModelLabels: result["shared_model_labels"] as? [String] ?? []
        )
    }

    func delete(loraID: String, modelKey: String, mode: LoRADeleteMode) async throws {
        let store = try store()
        var lc = try await loadCatalog()
        if mode == .deleteWeights {
            if let entry = LoRACatalog.getEntry(loraID: loraID, lc: lc),
               let path = entry.localPath {
                try? FileManager.default.removeItem(atPath: (path as NSString).expandingTildeInPath)
            }
            var users = lc[LoRACatalogSettings.userEntriesKey] as? [String: Any] ?? [:]
            users.removeValue(forKey: loraID)
            lc[LoRACatalogSettings.userEntriesKey] = users
        }
        var slice = LoRACatalogSettings.modelState(lc: lc, modelKey: modelKey)
        if !slice.deletedIDs.contains(loraID) { slice.deletedIDs.append(loraID) }
        slice.enabledIDs.removeAll { $0 == loraID }
        var byModel = lc[LoRACatalogSettings.byModelKey] as? [String: Any] ?? [:]
        byModel[modelKey] = [
            "enabled_ids": slice.enabledIDs,
            LoRACatalogSettings.deletedIDsKey: slice.deletedIDs,
        ]
        lc[LoRACatalogSettings.byModelKey] = byModel
        store.save(lc)
    }

    func findChoices() async throws -> [[String: Any]] {
        let store = try store()
        let lc = store.load()
        let profilePaths = config?.profilePaths ?? ProfilePaths(profilePath: nil)
        let choices = await Task.detached(priority: .userInitiated) {
            LoRAFindChoicesDiscovery.discover(lc: lc, profilePaths: profilePaths)
        }.value
        return LoRAFindChoicesDiscovery.bridgeDictionaries(from: choices)
    }

    func findOrigin(loraID: String) async throws -> [String: Any] {
        try await opsRequest(["command": "find_origin", "lora_id": loraID], awaitFinalResult: true)
    }

    func saveUserPreset() async throws {}
    func applyUserPreset() async throws {}
    func restoreRecommendations(modelKey: String) async throws { _ = modelKey }

    func checkLorasPrescan() async throws -> CheckLorasPrescanResult {
        let result = try await opsRequest(["command": "check_loras_prescan"])
        let choices = (result["choices"] as? [[String: Any]] ?? []).compactMap(CheckLorasProbeChoice.fromDictionary)
        let installed = (result["installed_models"] as? [[String: Any]] ?? []).compactMap { dict -> CheckLorasInstalledModel? in
            guard let key = dict["model_key"] as? String else { return nil }
            return CheckLorasInstalledModel(modelKey: key, displayName: dict["display_name"] as? String ?? key)
        }
        let saved = CheckLorasOptions.fromDictionary(result["saved_options"] as? [String: Any] ?? [:])
        return CheckLorasPrescanResult(choices: choices, installedModels: installed, savedOptions: saved)
    }

    func checkLorasSaveOptions(options: CheckLorasOptions) async throws {
        _ = try await opsRequest([
            "command": "check_loras_save_options",
            "options": options.bridgeDictionary(),
        ])
    }

    func checkLorasPrepare(options: CheckLorasOptions) async throws -> CheckLorasPrepareResult {
        let result = try await opsRequest(
            ["command": "check_loras_prepare", "options": options.bridgeDictionary()],
            awaitFinalResult: false
        )
        return CheckLorasPrepareResult(
            success: result["success"] as? Bool ?? false,
            cancelled: result["cancelled"] as? Bool ?? false,
            nothingToProbe: result["nothing_to_probe"] as? Bool ?? false,
            message: result["message"] as? String
        )
    }

    func checkLorasRun(
        options: CheckLorasOptions,
        onProgress: @escaping @Sendable ([String: Any]) -> Void
    ) async throws -> CheckLorasRunResult {
        let result = try await opsRequest(
            ["command": "check_loras_run", "options": options.bridgeDictionary()],
            awaitFinalResult: true,
            onProgress: onProgress
        )
        catalogStore?.invalidateCache()
        return CheckLorasRunResult(
            cancelled: result["cancelled"] as? Bool ?? false,
            probesDone: (result["probes_done"] as? NSNumber)?.intValue ?? 0,
            resultsText: result["results_text"] as? String ?? "",
            reportPaths: result["report_paths"] as? [String] ?? []
        )
    }

    func checkLorasCancel() async throws {
        _ = try await opsRequest(["command": "check_loras_cancel"])
    }

    func checkLorasProbeHistoryCount() async throws -> Int {
        let result = try await opsRequest([
            "command": "check_loras_clear_probe_history",
            "dry_run": true,
        ])
        return (result["count_before"] as? NSNumber)?.intValue ?? 0
    }

    func checkLorasClearProbeHistory() async throws -> Int {
        let result = try await opsRequest(["command": "check_loras_clear_probe_history"])
        catalogStore?.invalidateCache()
        return (result["removed"] as? NSNumber)?.intValue ?? 0
    }

    private nonisolated static func discoverDiskEntries(
        lc: [String: Any],
        savedPaths: [LoRACatalogEntry],
        profilePaths: ProfilePaths
    ) -> [LoRACatalogEntry] {
        let saved = Set(savedPaths.map(\.localPath))
        let orphans = LoRAFindChoicesDiscovery.discover(lc: lc, profilePaths: profilePaths)
            .filter { $0.key.hasPrefix("path:") }
            .filter { !saved.contains($0.weightsPath) }
        return orphans.map { choice in
            let path = choice.weightsPath
            let name = choice.displayName
            let fileName = URL(fileURLWithPath: path).lastPathComponent
            return LoRACatalogEntry(
                loraID: choice.key,
                displayName: name,
                label: name,
                hostID: "",
                scale: 1,
                bestGuess: 1,
                triggerWord: choice.triggerWord,
                comment: "",
                referencePrompt: "",
                repoID: "",
                filename: fileName,
                localPath: path,
                sourcePath: path,
                installed: true,
                lifecycle: "discovered",
                statusLabel: "Needs setup",
                hasRecoverySource: false,
                registered: false,
                probeStateForModel: "unknown"
            )
        }
    }

    private static func doubleMap(from raw: Any?) -> [String: Double] {
        guard let dict = raw as? [String: Any] else { return [:] }
        var out: [String: Double] = [:]
        for (key, value) in dict {
            if let n = value as? NSNumber { out[key] = n.doubleValue }
            else if let d = value as? Double { out[key] = d }
        }
        return out
    }
}

/// Back-compat alias while call sites migrate.
typealias LoRABridge = LoRAService
