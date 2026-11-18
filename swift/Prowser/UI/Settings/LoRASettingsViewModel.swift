import AppKit
import Foundation
import SwiftUI

extension Notification.Name {
    static let prowserSettingsWillCommit = Notification.Name("prowser.settingsWillCommit")
}

enum LoRASettingsListFilter: String, CaseIterable, Identifiable {
    case all = "All LoRA files"
    case worksWithModel = "Works with this model"

    var id: String { rawValue }
}

enum LoRASettingsRowKind: Equatable {
    case saved
    case needsSetup
}

enum LoRASettingsCompatibility: Equatable {
    case works
    case doesNotWork
    case notTested
}

struct LoRASettingsRow: Identifiable, Equatable {
    var entry: LoRACatalogEntry
    var kind: LoRASettingsRowKind
    var compatibility: LoRASettingsCompatibility?

    var id: String { entry.loraID }
}

@MainActor
@Observable
final class LoRASettingsViewModel {
    var models: [LoRASettingsModel] = []
    var selectedModelKey: String = ""
    var entries: [LoRACatalogEntry] = []
    var discoveredEntries: [LoRACatalogEntry] = []
    var rows: [LoRASettingsRow] = []
    var listFilter: LoRASettingsListFilter = .all
    var enabledIDs: Set<String> = []
    var hideUninstalled = false
    var isLoading = false
    var errorMessage: String?
    var draftByModel: [String: LoRAModelDraftSlice] = [:]
    var pendingImportPath: String?

    private weak var bridge: LoRABridge?
    private weak var config: AppConfig?

    func bind(bridge: LoRABridge, config: AppConfig) {
        self.bridge = bridge
        self.config = config
    }

    var selectedModel: LoRASettingsModel? {
        models.first { $0.modelKey == selectedModelKey }
    }

    var filteredRows: [LoRASettingsRow] {
        switch listFilter {
        case .all:
            return rows
        case .worksWithModel:
            return rows.filter { row in
                row.kind == .saved && row.compatibility == .works
            }
        }
    }

    func loadInitial() async {
        guard let bridge, bridge.isAvailable else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            models = try await bridge.settingsModels()
            if selectedModelKey.isEmpty {
                selectedModelKey = Self.resolveInitialModelKey(
                    models: models,
                    storedKey: config?.string(forKey: "imagegen_lora_model_key") ?? "",
                    sessionKey: SettingsTab.lastSessionLoraModelKey
                )
            }
            await reloadEntries()
        } catch {
            errorMessage = error.localizedDescription
            models = []
        }
    }

    func reloadEntries() async {
        guard let bridge, !selectedModelKey.isEmpty else { return }
        let storageKey = catalogStorageModelKey(for: selectedModelKey)
        do {
            var draftsForBridge = draftByModel
            if storageKey != selectedModelKey, let slice = draftByModel[storageKey] {
                draftsForBridge[selectedModelKey] = slice
            }
            let result = try await bridge.settingsEntries(
                modelKey: selectedModelKey,
                hideUninstalled: hideUninstalled,
                draftByModel: draftsForBridge
            )
            entries = result.entries
            discoveredEntries = []
            let installedIDs = Set(entries.filter(\.installed).map(\.loraID))
            let prunedEnabled = result.enabledIDs.filter { installedIDs.contains($0) }
            enabledIDs = Set(prunedEnabled)
            draftByModel[storageKey] = LoRAModelDraftSlice(
                enabledIDs: prunedEnabled,
                deletedIDs: result.deletedIDs
            )
            rebuildRows()
            let modelKey = selectedModelKey
            let savedSnapshot = entries
            let catalogSnapshot = result.catalog
            Task { [weak self] in
                guard let self, let bridge = self.bridge else { return }
                do {
                    let discovered = try await bridge.settingsDownloadedEntries(
                        savedEntries: savedSnapshot,
                        catalog: catalogSnapshot
                    )
                    guard self.selectedModelKey == modelKey else { return }
                    self.discoveredEntries = discovered
                    self.rebuildRows()
                } catch {
                    // Non-fatal: catalog rows are already visible.
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rebuildRows() {
        var built: [LoRASettingsRow] = entries.map { entry in
            LoRASettingsRow(
                entry: entry,
                kind: .saved,
                compatibility: compatibility(for: entry)
            )
        }
        let discovered = discoveredEntries.map { entry in
            LoRASettingsRow(
                entry: entry,
                kind: .needsSetup,
                compatibility: nil
            )
        }
        built.append(contentsOf: discovered)
        built = dedupeRows(built)
        built.sort { lhs, rhs in
            if lhs.kind != rhs.kind {
                return lhs.kind == .saved
            }
            return lhs.entry.label.localizedCaseInsensitiveCompare(rhs.entry.label) == .orderedAscending
        }
        rows = built
    }

    private func dedupeRows(_ rows: [LoRASettingsRow]) -> [LoRASettingsRow] {
        var seenIDs: Set<String> = []
        var seenWeightKeys: Set<String> = []
        var seenNameSizeKeys: Set<String> = []
        var out: [LoRASettingsRow] = []
        for row in rows {
            if seenIDs.contains(row.entry.loraID) {
                continue
            }
            let path = row.entry.localPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                let key = (path as NSString).standardizingPath
                if seenWeightKeys.contains(key) {
                    continue
                }
                seenWeightKeys.insert(key)
                if let nameSizeKey = weightsDedupeKey(standardizedPath: key, label: row.entry.label) {
                    if seenNameSizeKeys.contains(nameSizeKey) {
                        continue
                    }
                    seenNameSizeKeys.insert(nameSizeKey)
                }
            }
            seenIDs.insert(row.entry.loraID)
            out.append(row)
        }
        return out
    }

    /// Same weights copied to cache, Downloads, and a `_2` folder share name + byte size.
    private func weightsDedupeKey(standardizedPath: String, label: String) -> String? {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: standardizedPath),
              let size = attrs[.size] as? UInt64,
              size > 0
        else { return nil }
        return "name:\(name)|\(size)"
    }

    private func compatibility(for entry: LoRACatalogEntry) -> LoRASettingsCompatibility {
        switch entry.probeStateForModel {
        case "pass":
            return .works
        case "fail":
            return .doesNotWork
        default:
            return .notTested
        }
    }

    func compatibilitySubtitle(for row: LoRASettingsRow) -> String {
        let modelLabel = selectedModel?.displayName ?? "this model"
        switch row.kind {
        case .needsSetup:
            return row.entry.statusLabel.isEmpty ? "Needs setup" : row.entry.statusLabel
        case .saved:
            switch row.compatibility {
            case .works:
                return "Works with \(modelLabel)"
            case .doesNotWork:
                return "Doesn't work with \(modelLabel)"
            case .notTested:
                return "Not tested yet — run Test LoRAs"
            case .none:
                return row.entry.statusLabel
            }
        }
    }

    func modelChanged(to key: String) async {
        persistCurrentModelDraft()
        selectedModelKey = key
        persistModelSelection(key)
        await reloadEntries()
    }

    private func persistModelSelection(_ key: String) {
        SettingsTab.rememberSessionLoraModelKey(key)
    }

    private static func resolveInitialModelKey(
        models: [LoRASettingsModel],
        storedKey: String,
        sessionKey: String?
    ) -> String {
        let validKeys = Set(models.map(\.modelKey))
        if let sessionKey {
            let trimmed = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, validKeys.contains(trimmed) {
                return trimmed
            }
        }
        let stored = storedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty, validKeys.contains(stored) {
            return stored
        }
        if validKeys.contains(LoRAHFModelIDs.flux1Dev) {
            return LoRAHFModelIDs.flux1Dev
        }
        return models.first?.modelKey ?? ""
    }

    func canEnableInCreateMenu(_ row: LoRASettingsRow) -> Bool {
        row.kind == .saved && row.compatibility == .works && row.entry.installed
    }

    func showsEnabledInUI(loraID: String) -> Bool {
        guard entries.first(where: { $0.loraID == loraID })?.installed == true else { return false }
        return enabledIDs.contains(loraID)
    }

    func enableCheckboxHelp(for row: LoRASettingsRow) -> String {
        if canEnableInCreateMenu(row) { return "In Create menu" }
        if row.compatibility == .works, !row.entry.installed {
            return "Install weights before adding to Create menu"
        }
        return "Works with this model before enabling"
    }

    func toggleEnabled(_ loraID: String, enabled: Bool) {
        guard entries.first(where: { $0.loraID == loraID })?.installed == true else { return }
        if enabled {
            enabledIDs.insert(loraID)
        } else {
            enabledIDs.remove(loraID)
        }
        persistCurrentModelDraft()
        rebuildRows()
    }

    func persistCurrentModelDraft() {
        guard !selectedModelKey.isEmpty else { return }
        let storageKey = catalogStorageModelKey(for: selectedModelKey)
        let slice = draftByModel[storageKey] ?? LoRAModelDraftSlice(enabledIDs: [], deletedIDs: [])
        draftByModel[storageKey] = LoRAModelDraftSlice(
            enabledIDs: Array(enabledIDs).sorted(),
            deletedIDs: slice.deletedIDs
        )
    }

    private func catalogStorageModelKey(for settingsModelKey: String) -> String {
        LoRAModelRegistry.canonicalSettingsModelKey(settingsModelKey)
    }

    func commitToDisk() async throws {
        guard let bridge else { return }
        persistCurrentModelDraft()
        try await bridge.saveCatalogState(modelKey: selectedModelKey, byModel: draftByModel)
        NotificationCenter.default.post(name: .prowserLoraCatalogChanged, object: nil)
    }

    func install(loraID: String, parentWindow: NSWindow?) async {
        guard let bridge else { return }
        guard let catalogEntry = entries.first(where: { $0.loraID == loraID }) else {
            errorMessage = "LoRA \(loraID) was not found."
            return
        }
        let recoverable = LoRAEntry.hasRecoverySource(
            repoID: catalogEntry.repoID,
            filename: catalogEntry.filename,
            sourcePath: catalogEntry.sourcePath,
            safetensorsOrigin: catalogEntry.safetensorsOrigin,
            webPageURL: catalogEntry.webPageURL,
            localPath: catalogEntry.localPath.isEmpty ? nil : catalogEntry.localPath
        )
        guard recoverable else {
            errorMessage = LoRAInstallError.noRecoverySource.errorDescription
            return
        }
        let canDownload = LoRAInstallService.canDownloadWeights(
            repoID: catalogEntry.repoID,
            filename: catalogEntry.filename,
            sourcePath: catalogEntry.sourcePath.isEmpty ? nil : catalogEntry.sourcePath,
            safetensorsOrigin: catalogEntry.safetensorsOrigin.isEmpty ? nil : catalogEntry.safetensorsOrigin,
            localPath: catalogEntry.localPath.isEmpty ? nil : catalogEntry.localPath
        )
        if let pageURL = LoRAInstallService.webPageToOpenInsteadOfInstall(
            repoID: catalogEntry.repoID,
            filename: catalogEntry.filename,
            sourcePath: catalogEntry.sourcePath.isEmpty ? nil : catalogEntry.sourcePath,
            safetensorsOrigin: catalogEntry.safetensorsOrigin.isEmpty ? nil : catalogEntry.safetensorsOrigin,
            webPageURL: catalogEntry.webPageURL,
            canDownload: canDownload
        ) {
            NSWorkspace.shared.open(pageURL)
            return
        }
        if !canDownload {
            errorMessage = LoRAInstallError.noRecoverySource.errorDescription
            return
        }
        let source = LoRAInstallService.installSourceDescription(
            repoID: catalogEntry.repoID,
            filename: catalogEntry.filename,
            sourcePath: catalogEntry.sourcePath,
            safetensorsOrigin: catalogEntry.safetensorsOrigin
        )
        let confirm = StyledMessageDialog.showConfirm(
            title: "Install LoRA",
            message: "Download weights for «\(catalogEntry.displayName)»?",
            secondaryMessage: source,
            confirmTitle: "Download",
            cancelTitle: "Cancel",
            defaultCancel: true,
            parentWindow: parentWindow
        )
        guard confirm else { return }

        do {
            try await bridge.install(loraID: loraID, modelKey: selectedModelKey)
            await reloadEntries()
            NotificationCenter.default.post(name: .prowserLoraCatalogChanged, object: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeSavedLoRA(
        loraID: String,
        parentWindow: NSWindow?
    ) async {
        guard let bridge else { return }
        do {
            let info = try await bridge.loraRemovalInfo(loraID: loraID)
            let outcome = LoRARemovalFlow.run(info: info, parentWindow: parentWindow)
            switch outcome {
            case .cancelled:
                return
            case .removedCompatibilityState:
                try await bridge.delete(
                    loraID: loraID,
                    modelKey: selectedModelKey,
                    mode: .unregister
                )
            case .deletedWeights:
                try await bridge.delete(
                    loraID: loraID,
                    modelKey: selectedModelKey,
                    mode: .deleteWeights
                )
            }
            await syncDraftAfterLoRARemoval(loraID: loraID)
            await reloadEntries()
            NotificationCenter.default.post(name: .prowserLoraCatalogChanged, object: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func applyUserPreset() async {
        guard let bridge else { return }
        do {
            try await bridge.applyUserPreset()
            await loadInitial()
            NotificationCenter.default.post(name: .prowserLoraCatalogChanged, object: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveUserPreset() async {
        guard let bridge else { return }
        do {
            try await commitToDisk()
            try await bridge.saveUserPreset()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectModelKey(_ key: String) async {
        if models.contains(where: { $0.modelKey == key }) {
            await modelChanged(to: key)
        }
    }

    /// Keep in-memory drafts aligned with disk after delete so reload and Settings commit do not undo removal.
    private func syncDraftAfterLoRARemoval(loraID: String) async {
        enabledIDs.remove(loraID)
        for key in draftByModel.keys {
            var slice = draftByModel[key] ?? LoRAModelDraftSlice(enabledIDs: [], deletedIDs: [])
            slice.enabledIDs.removeAll { $0 == loraID }
            draftByModel[key] = slice
        }
        guard let bridge, !selectedModelKey.isEmpty else { return }
        if let diskSlice = try? await bridge.diskModelSlice(modelKey: selectedModelKey) {
            draftByModel[selectedModelKey] = diskSlice
            enabledIDs = Set(diskSlice.enabledIDs)
        }
    }
}
