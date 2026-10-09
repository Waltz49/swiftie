import Foundation
import SwiftUI

extension Notification.Name {
    static let prowserSettingsWillCommit = Notification.Name("prowser.settingsWillCommit")
}

@MainActor
@Observable
final class LoRASettingsViewModel {
    var models: [LoRASettingsModel] = []
    var selectedModelKey: String = ""
    var entries: [LoRACatalogEntry] = []
    var discoveredEntries: [LoRACatalogEntry] = []
    var enabledIDs: Set<String> = []
    var hideUninstalled = true
    var isLoading = false
    var errorMessage: String?
    var draftByModel: [String: LoRAModelDraftSlice] = [:]
    private var baselineDrafts: [String: LoRAModelDraftSlice] = [:]
    var pendingImportPath: String?

    private weak var bridge: LoRABridge?

    func bind(bridge: LoRABridge) {
        self.bridge = bridge
    }

    var selectedModel: LoRASettingsModel? {
        models.first { $0.modelKey == selectedModelKey }
    }

    func loadInitial() async {
        guard let bridge, bridge.isAvailable else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            models = try await bridge.settingsModels()
            if selectedModelKey.isEmpty {
                selectedModelKey = models.first?.modelKey ?? ""
            }
            await reloadEntries()
            baselineDrafts = draftByModel
        } catch {
            errorMessage = error.localizedDescription
            models = []
        }
    }

    func reloadEntries() async {
        guard let bridge, !selectedModelKey.isEmpty else { return }
        do {
            let slice = draftByModel[selectedModelKey] ?? LoRAModelDraftSlice(enabledIDs: [], deletedIDs: [])
            let result = try await bridge.settingsEntries(
                modelKey: selectedModelKey,
                hideUninstalled: hideUninstalled,
                draftByModel: draftByModel
            )
            entries = result.entries
            discoveredEntries = result.discoveredEntries
            enabledIDs = Set(result.enabledIDs)
            draftByModel[selectedModelKey] = LoRAModelDraftSlice(
                enabledIDs: result.enabledIDs,
                deletedIDs: result.deletedIDs
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func modelChanged(to key: String) async {
        persistCurrentModelDraft()
        selectedModelKey = key
        await reloadEntries()
    }

    func toggleEnabled(_ loraID: String, enabled: Bool) {
        if enabled {
            enabledIDs.insert(loraID)
        } else {
            enabledIDs.remove(loraID)
        }
        persistCurrentModelDraft()
    }

    func persistCurrentModelDraft() {
        guard !selectedModelKey.isEmpty else { return }
        let slice = draftByModel[selectedModelKey] ?? LoRAModelDraftSlice(enabledIDs: [], deletedIDs: [])
        draftByModel[selectedModelKey] = LoRAModelDraftSlice(
            enabledIDs: Array(enabledIDs).sorted(),
            deletedIDs: slice.deletedIDs
        )
    }

    func commitToDisk() async throws {
        guard let bridge else { return }
        persistCurrentModelDraft()
        try await bridge.saveCatalogState(modelKey: selectedModelKey, byModel: draftByModel)
        baselineDrafts = draftByModel
        NotificationCenter.default.post(name: .prowserLoraCatalogChanged, object: nil)
    }

    func install(loraID: String) async {
        guard let bridge else { return }
        do {
            try await bridge.install(loraID: loraID, modelKey: selectedModelKey)
            await reloadEntries()
            NotificationCenter.default.post(name: .prowserLoraCatalogChanged, object: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(loraID: String) async {
        guard let bridge else { return }
        do {
            try await bridge.delete(loraID: loraID, modelKey: selectedModelKey)
            enabledIDs.remove(loraID)
            persistCurrentModelDraft()
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
}
