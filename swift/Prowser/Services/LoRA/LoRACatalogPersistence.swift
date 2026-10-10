import Foundation

/// Save LoRA catalog slices (port of `save_lora_catalog_state`).
@MainActor
enum LoRACatalogPersistence {
    static func saveCatalogState(
        byModel: [String: LoRAModelDraftSlice],
        store: LoRACatalogStore
    ) {
        var lc = store.load()
        let catalog = LoRACatalog.mergedCatalog(lc: lc)
        var byModelDict = (lc[LoRACatalogSettings.byModelKey] as? [String: Any]) ?? [:]
        for (modelKey, slice) in byModel {
            let enabled = slice.enabledIDs.filter { catalog[$0] != nil }
            let deleted = slice.deletedIDs.filter { catalog[$0] != nil }
            byModelDict[modelKey] = [
                "enabled_ids": enabled,
                LoRACatalogSettings.deletedIDsKey: deleted,
            ]
        }
        lc[LoRACatalogSettings.byModelKey] = byModelDict
        store.save(lc)
    }
}
