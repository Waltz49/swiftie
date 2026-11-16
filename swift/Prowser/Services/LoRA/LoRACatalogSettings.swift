import Foundation

/// Per-base-model LoRA catalog state (port of `lora_catalog_settings.py`).
enum LoRACatalogSettings {
    static let userEntriesKey = "user_entries"
    static let byHostKey = "by_host"
    static let byModelKey = "by_model"
    static let entryOverridesKey = "entry_overrides"
    static let probeHistoryKey = "probe_history"
    static let crossFamilyModelsKey = "cross_family_models"
    static let deletedIDsKey = "deleted_ids"
    static let legacyHiddenKey = "hidden_ids"
    static let catalogSchemaKey = "catalog_schema"
    static let diskFirstSchema = "disk_first_v1"

    struct ModelSlice: Equatable {
        var enabledIDs: [String]
        var deletedIDs: [String]
    }

    static func emptySlice() -> ModelSlice {
        ModelSlice(enabledIDs: [], deletedIDs: [])
    }

    static func migrateCatalog(_ lc: [String: Any]) -> [String: Any] {
        migrateCatalogIfNeeded(lc).catalog
    }

    static func migrateCatalogIfNeeded(_ lc: [String: Any]) -> (catalog: [String: Any], changed: Bool) {
        let before = canonicalJSONData(lc)
        var out = lc
        migrateLegacyZImage(&out)

        var byHost = (out[byHostKey] as? [String: Any]) ?? defaultByHost()
        for hostID in LoRAHostRegistry.hostOrder {
            let slice = byHost[hostID] as? [String: Any]
            byHost[hostID] = normalizeHostSlice(hostID: hostID, slice: slice, catalog: userEntries(from: out))
        }
        out[byHostKey] = byHost

        ensureByModel(&out, byHost: byHost)

        if out[userEntriesKey] == nil { out[userEntriesKey] = [String: Any]() }
        if out[crossFamilyModelsKey] == nil { out[crossFamilyModelsKey] = [String: Any]() }
        if out[entryOverridesKey] == nil { out[entryOverridesKey] = [String: Any]() }
        out[probeHistoryKey] = normalizeProbeHistory(out[probeHistoryKey])
        if out[catalogSchemaKey] as? String != diskFirstSchema,
           !needsLegacyPythonDiskFirstMigration(out) {
            out[catalogSchemaKey] = diskFirstSchema
        }
        let after = canonicalJSONData(out)
        let changed = before != after
        return (out, changed)
    }

    private static func canonicalJSONData(_ dict: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data()
    }

    static func userEntries(from lc: [String: Any]) -> [String: LoRAEntry] {
        LoRAUserEntries.entries(from: lc)
    }

    static func modelState(lc: [String: Any], modelKey: String) -> ModelSlice {
        let byModel = lc[byModelKey] as? [String: Any] ?? [:]
        guard let slice = byModel[modelKey] as? [String: Any] else { return emptySlice() }
        return ModelSlice(
            enabledIDs: (slice["enabled_ids"] as? [String]) ?? [],
            deletedIDs: deletedIDs(from: slice)
        )
    }

    /// Drop saved user LoRA metadata and compatibility state; keep weight files on disk (Python ``unregister_user_lora``).
    static func purgeUserLoraSettings(loraID: String, in lc: inout [String: Any]) {
        let lid = loraID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lid.isEmpty, LoRAEntry.isUserLoraID(lid) else { return }

        if var raw = lc[userEntriesKey] as? [String: Any] {
            raw.removeValue(forKey: lid)
            lc[userEntriesKey] = raw
        }
        if var ms = lc["model_support"] as? [String: Any] {
            ms.removeValue(forKey: lid)
            lc["model_support"] = ms
        }
        if var cfm = lc[crossFamilyModelsKey] as? [String: Any] {
            cfm.removeValue(forKey: lid)
            lc[crossFamilyModelsKey] = cfm
        }
        if var ph = lc[probeHistoryKey] as? [String: Any] {
            ph.removeValue(forKey: lid)
            lc[probeHistoryKey] = ph
        }
        if var overrides = lc[entryOverridesKey] as? [String: Any] {
            overrides.removeValue(forKey: lid)
            lc[entryOverridesKey] = overrides
        }
        if var byModel = lc[byModelKey] as? [String: Any] {
            for (modelKey, value) in byModel {
                guard var slice = value as? [String: Any] else { continue }
                var enabled = (slice["enabled_ids"] as? [String]) ?? []
                enabled.removeAll { $0 == lid }
                slice["enabled_ids"] = enabled
                byModel[modelKey] = slice
            }
            lc[byModelKey] = byModel
        }
    }

    static func hideCatalogLoraFromModel(loraID: String, modelKey: String, in lc: inout [String: Any]) {
        let lid = loraID.trimmingCharacters(in: .whitespacesAndNewlines)
        let mk = modelKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lid.isEmpty, !mk.isEmpty else { return }

        var slice = modelState(lc: lc, modelKey: mk)
        if !slice.deletedIDs.contains(lid) {
            slice.deletedIDs.append(lid)
        }
        slice.enabledIDs.removeAll { $0 == lid }
        var byModel = lc[byModelKey] as? [String: Any] ?? [:]
        byModel[mk] = [
            "enabled_ids": slice.enabledIDs,
            deletedIDsKey: slice.deletedIDs,
        ]
        lc[byModelKey] = byModel
    }

    static func enabledIDs(lc: [String: Any], modelKey: String) -> [String] {
        let catalog = userEntries(from: lc)
        let ms = modelSupportDict(lc)
        let slice = modelState(lc: lc, modelKey: modelKey)
        return slice.enabledIDs.filter { lid in
            guard let entry = catalog[lid] else { return false }
            return LoRAModelRegistry.entryMatchesModel(entry, modelKey: modelKey, modelSupport: ms)
                || entryVisibleForUserHost(entry, modelKey: modelKey)
        }
    }

    private static func entryVisibleForUserHost(_ entry: LoRAEntry, modelKey: String) -> Bool {
        guard LoRAEntry.isUserLoraID(entry.loraID) else { return false }
        let expected = LoRAModelRegistry.hostID(forModelKey: modelKey)
        return expected == entry.hostID
    }

    static func deletedIDs(for modelKey: String, lc: [String: Any], draftByModel: [String: LoRAModelDraftSlice]?) -> Set<String> {
        if let draft = draftByModel?[modelKey] {
            return Set(draft.deletedIDs)
        }
        return Set(modelState(lc: lc, modelKey: modelKey).deletedIDs)
    }

    /// Python ``migrate_disk_first_catalog_if_needed`` (built-in ID remap). Skip when Swift can stamp schema only.
    static func needsPythonDiskFirstMigration(_ lc: [String: Any]) -> Bool {
        guard lc[catalogSchemaKey] as? String != diskFirstSchema else { return false }
        return needsLegacyPythonDiskFirstMigration(lc)
    }

    static func needsLegacyPythonDiskFirstMigration(_ lc: [String: Any]) -> Bool {
        let userIDs = Set(userEntries(from: lc).keys)
        if let overrides = lc[entryOverridesKey] as? [String: Any] {
            for key in overrides.keys {
                let id = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, !userIDs.contains(id) else { continue }
                if !LoRAEntry.isUserLoraID(id) {
                    return true
                }
            }
        }
        for slice in hostAndModelSlices(in: lc) {
            for id in slice.enabledIDs + slice.deletedIDs {
                guard !userIDs.contains(id) else { continue }
                if !LoRAEntry.isUserLoraID(id) {
                    return true
                }
            }
        }
        return false
    }

    private static func hostAndModelSlices(in lc: [String: Any]) -> [ModelSlice] {
        var slices: [ModelSlice] = []
        for key in [byHostKey, byModelKey] {
            guard let dict = lc[key] as? [String: Any] else { continue }
            for (_, raw) in dict {
                guard let slice = raw as? [String: Any] else { continue }
                slices.append(
                    ModelSlice(
                        enabledIDs: (slice["enabled_ids"] as? [String]) ?? [],
                        deletedIDs: deletedIDs(from: slice)
                    )
                )
            }
        }
        return slices
    }

    static func enabledIDList(
        for modelKey: String,
        lc: [String: Any],
        draftByModel: [String: LoRAModelDraftSlice]?
    ) -> [String] {
        if let draft = draftByModel?[modelKey] {
            return draft.enabledIDs
        }
        return modelState(lc: lc, modelKey: modelKey).enabledIDs
    }

    static func modelSupportDict(_ lc: [String: Any]) -> [String: [String]] {
        guard let raw = lc["model_support"] as? [String: Any] else { return [:] }
        var out: [String: [String]] = [:]
        for (lid, value) in raw {
            if let list = value as? [String] {
                out[lid] = list
            } else if let list = value as? [Any] {
                out[lid] = list.map { String(describing: $0) }
            }
        }
        return out
    }

    static func applyEntryOverrides(_ entry: LoRAEntry, overrides: [String: Any]?) -> LoRAEntry {
        guard let overrides else { return entry }
        var e = entry
        if let name = (overrides["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            e.displayName = name
        }
        if overrides.keys.contains("trigger_word") {
            let t = (overrides["trigger_word"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            e.triggerWord = t?.isEmpty == true ? nil : t
        }
        if let scale = overrides["scale"] as? NSNumber { e.scale = scale.doubleValue }
        if let bg = overrides["best_guess"] as? NSNumber { e.bestGuess = bg.doubleValue }
        if overrides.keys.contains("comment") {
            let c = (overrides["comment"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            e.comment = c?.isEmpty == true ? nil : c
        }
        if overrides.keys.contains("reference_prompt") {
            let r = (overrides["reference_prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            e.referencePrompt = r?.isEmpty == true ? nil : r
        }
        return e
    }

    static func entryOverrides(from lc: [String: Any]) -> [String: [String: Any]] {
        guard let raw = lc[entryOverridesKey] as? [String: Any] else { return [:] }
        var out: [String: [String: Any]] = [:]
        for (lid, slice) in raw {
            if let dict = slice as? [String: Any] { out[lid] = dict }
        }
        return out
    }

    private static func defaultByHost() -> [String: Any] {
        var out: [String: Any] = [:]
        for host in LoRAHostRegistry.hostOrder {
            out[host] = ["enabled_ids": [], deletedIDsKey: []]
        }
        return out
    }

    private static func defaultByModel() -> [String: Any] {
        var out: [String: Any] = [:]
        for key in LoRAHFModelIDs.probeModelOrder {
            out[key] = ["enabled_ids": [], deletedIDsKey: []]
        }
        return out
    }

    private static func deletedIDs(from slice: [String: Any]) -> [String] {
        if let d = slice[deletedIDsKey] as? [String], !d.isEmpty { return d }
        if let h = slice[legacyHiddenKey] as? [String] { return h }
        return []
    }

    private static func normalizeHostSlice(hostID: String, slice: [String: Any]?, catalog: [String: LoRAEntry]) -> [String: Any] {
        let slice = slice ?? ["enabled_ids": [], deletedIDsKey: []]
        let enabled = (slice["enabled_ids"] as? [Any] ?? []).map { String(describing: $0) }
            .filter { catalog[$0]?.hostID == hostID }
        return ["enabled_ids": enabled, deletedIDsKey: deletedIDs(from: slice)]
    }

    private static func normalizeModelSlice(
        modelKey: String,
        slice: [String: Any]?,
        catalog: [String: LoRAEntry],
        modelSupport: [String: [String]]
    ) -> [String: Any] {
        let slice = slice ?? ["enabled_ids": [], deletedIDsKey: []]
        let enabled = (slice["enabled_ids"] as? [Any] ?? []).map { String(describing: $0) }
            .filter { lid in
                guard let entry = catalog[lid] else { return false }
                return LoRAModelRegistry.entryMatchesModel(entry, modelKey: modelKey, modelSupport: modelSupport)
                    || (LoRAEntry.isUserLoraID(entry.loraID) && LoRAModelRegistry.hostID(forModelKey: modelKey) == entry.hostID)
            }
        let deleted = deletedIDs(from: slice).filter { lid in
            guard let entry = catalog[lid] else { return false }
            return LoRAModelRegistry.entryMatchesModel(entry, modelKey: modelKey, modelSupport: modelSupport)
                || (LoRAEntry.isUserLoraID(entry.loraID) && LoRAModelRegistry.hostID(forModelKey: modelKey) == entry.hostID)
        }
        return ["enabled_ids": enabled, deletedIDsKey: deleted]
    }

    private static func ensureByModel(_ lc: inout [String: Any], byHost: [String: Any]) {
        let catalog = userEntries(from: lc)
        let ms = modelSupportDict(lc)
        var byModel = (lc[byModelKey] as? [String: Any]) ?? defaultByModel()
        for modelKey in LoRAHFModelIDs.probeModelOrder {
            let slice = byModel[modelKey] as? [String: Any]
            byModel[modelKey] = normalizeModelSlice(
                modelKey: modelKey,
                slice: slice,
                catalog: catalog,
                modelSupport: ms
            )
        }
        lc[byModelKey] = byModel
    }

    private static func migrateLegacyZImage(_ lc: inout [String: Any]) {
        let canonical = LoRAHFModelIDs.zImageTurbo
        let legacy = LoRAHFModelIDs.legacyZMfluxHFIDs
        guard var byModel = lc[byModelKey] as? [String: Any] else { return }
        var target = (byModel[canonical] as? [String: Any]) ?? ["enabled_ids": [], deletedIDsKey: []]
        for legacyKey in legacy where legacyKey != canonical {
            if let slice = byModel.removeValue(forKey: legacyKey) as? [String: Any] {
                mergeSlices(into: &target, from: slice)
            }
        }
        byModel[canonical] = target
        lc[byModelKey] = byModel
    }

    private static func mergeSlices(into target: inout [String: Any], from: [String: Any]) {
        for key in ["enabled_ids", deletedIDsKey] {
            var merged = (target[key] as? [String]) ?? []
            let seen = Set(merged)
            for x in (from[key] as? [String]) ?? [] {
                if !seen.contains(x) { merged.append(x) }
            }
            target[key] = merged
        }
    }

    private static func normalizeProbeHistory(_ raw: Any?) -> [String: Any] {
        guard let dict = raw as? [String: Any] else { return [:] }
        return dict
    }
}
