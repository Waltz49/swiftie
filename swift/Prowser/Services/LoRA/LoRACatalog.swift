import Foundation

/// Disk-first LoRA catalog facade (port of `lora_catalog.py` subset).
enum LoRACatalog {
    static func mergedCatalog(lc: [String: Any]) -> [String: LoRAEntry] {
        LoRAUserEntries.mergedCatalog(lc: lc)
    }

    static func isInstalled(entry: LoRAEntry) -> Bool {
        LoRAPathResolver.localWeightsPath(loraID: entry.loraID, entry: entry) != nil
    }

    static func getEntry(loraID: String, lc: [String: Any]) -> LoRAEntry? {
        var entry = mergedCatalog(lc: lc)[loraID]
        guard var resolved = entry else { return nil }
        let overrides = LoRACatalogSettings.entryOverrides(from: lc)[loraID]
        resolved = LoRACatalogSettings.applyEntryOverrides(resolved, overrides: overrides)
        return resolved
    }

    static func catalogEntriesSorted(lc: [String: Any]) -> [LoRAEntry] {
        mergedCatalog(lc: lc).values.sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
    }

    static func choiceLabel(entry: LoRAEntry, modelKey: String) -> String {
        let base = baseDisplayName(entry: entry, modelKey: modelKey)
        guard let trigger = entry.triggerWord?.trimmingCharacters(in: .whitespacesAndNewlines), !trigger.isEmpty else {
            return base
        }
        let maxLen = 30
        let shown = trigger.count > maxLen ? String(trigger.prefix(maxLen - 3)) + "..." : trigger
        return "\(base) - Trigger: \(shown)"
    }

    static func baseDisplayName(entry: LoRAEntry, modelKey: String) -> String {
        entry.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func probePassed(
        loraID: String,
        modelKey: String,
        entry: LoRAEntry?,
        modelSupport: [String: [String]]
    ) -> Bool {
        let resolved = entry ?? LoRAEntry(
            hostID: "", loraID: loraID, displayName: loraID, repoID: "", filename: "",
            scale: 1, bestGuess: 1, localPath: nil, baseHFModelID: "", minSteps: 2,
            mfluxCompatible: nil, triggerWord: nil, comment: nil, referencePrompt: nil, sourcePath: nil
        )
        if resolved.mfluxCompatible == false { return false }
        if !LoRAModelRegistry.entryMatchesModel(resolved, modelKey: modelKey, modelSupport: modelSupport) {
            if LoRAEntry.isUserLoraID(resolved.loraID) {
                let expected = LoRAModelRegistry.hostID(forModelKey: modelKey)
                if expected == resolved.hostID {
                    return resolved.mfluxCompatible == true
                        || LoRAModelRegistry.probeSupportedOnModel(entry: resolved, modelKey: modelKey, modelSupport: modelSupport)
                }
            }
            if resolved.mfluxCompatible == true { return true }
            return LoRAModelRegistry.probeSupportedOnModel(entry: resolved, modelKey: modelKey, modelSupport: modelSupport)
        }
        if resolved.mfluxCompatible == true { return true }
        return LoRAModelRegistry.probeSupportedOnModel(entry: resolved, modelKey: modelKey, modelSupport: modelSupport)
    }

    static func entryVisibleInSettings(
        entry: LoRAEntry,
        modelKey: String,
        lc: [String: Any],
        draftByModel: [String: LoRAModelDraftSlice]?
    ) -> Bool {
        if entry.mfluxCompatible == false { return false }
        let deleted = LoRACatalogSettings.deletedIDs(for: modelKey, lc: lc, draftByModel: draftByModel)
        if deleted.contains(entry.loraID) { return false }
        let ms = LoRACatalogSettings.modelSupportDict(lc)
        if LoRAModelRegistry.probeSupportedOnModel(entry: entry, modelKey: modelKey, modelSupport: ms) {
            return true
        }
        if crossFamily(entry: entry, loraID: entry.loraID, modelKey: modelKey, lc: lc) { return true }
        if LoRAEntry.isUserLoraID(entry.loraID) {
            return LoRAModelRegistry.hostID(forModelKey: modelKey) == entry.hostID
        }
        let entryModels = LoRAModelRegistry.modelsForEntry(entry)
        return LoRAModelRegistry.kleinAliases(for: modelKey).contains(where: { entryModels.contains($0) })
    }

    static func crossFamily(entry: LoRAEntry, loraID: String, modelKey: String, lc: [String: Any]) -> Bool {
        let raw = lc[LoRACatalogSettings.crossFamilyModelsKey] as? [String: Any] ?? [:]
        if let list = raw[loraID] as? [String], list.contains(modelKey) { return true }
        let ms = LoRAModelRegistry.probeSupportedOnModel(
            entry: entry, modelKey: modelKey, modelSupport: LoRACatalogSettings.modelSupportDict(lc)
        )
        if !ms { return false }
        return LoRAModelRegistry.isCrossFamily(entry: entry, modelKey: modelKey)
    }

    static func settingsEntries(
        lc: [String: Any],
        modelKey: String,
        draftByModel: [String: LoRAModelDraftSlice]?
    ) -> [LoRAEntry] {
        catalogEntriesSorted(lc: lc).filter {
            entryVisibleInSettings(entry: $0, modelKey: modelKey, lc: lc, draftByModel: draftByModel)
        }
    }

    static func choicesForPlugin(plugin: ImageGenPluginDescriptor, lc: [String: Any]) -> [(label: String, id: String)] {
        guard let hostID = plugin.loraHostID else { return [("None", "none")] }
        let modelKey = plugin.hfModelID
        let enabled = Set(LoRACatalogSettings.enabledIDs(lc: lc, modelKey: modelKey))
        let ms = LoRACatalogSettings.modelSupportDict(lc)
        var choices: [(String, String)] = [("None", "none")]
        if enabled.isEmpty { return choices }
        for entry in catalogEntriesSorted(lc: lc) {
            guard enabled.contains(entry.loraID) else { continue }
            if visibleForRun(entry: entry, modelKey: modelKey, hostID: hostID, lc: lc, enabled: enabled, modelSupport: ms) {
                choices.append((choiceLabel(entry: entry, modelKey: modelKey), entry.loraID))
            }
        }
        return choices
    }

    static func visibleForRun(
        entry: LoRAEntry,
        modelKey: String,
        hostID: String,
        lc: [String: Any],
        enabled: Set<String>,
        modelSupport: [String: [String]]
    ) -> Bool {
        if entry.mfluxCompatible == false { return false }
        if !enabled.contains(entry.loraID) { return false }
        if !probePassed(loraID: entry.loraID, modelKey: modelKey, entry: entry, modelSupport: modelSupport) {
            return false
        }
        return LoRAPathResolver.localWeightsPath(loraID: entry.loraID, entry: entry) != nil
    }

    static func lifecycleState(
        loraID: String,
        modelKey: String,
        lc: [String: Any],
        draftByModel: [String: LoRAModelDraftSlice]?
    ) -> String {
        let deleted = LoRACatalogSettings.deletedIDs(for: modelKey, lc: lc, draftByModel: draftByModel)
        if deleted.contains(loraID) { return "deleted" }
        let enabled = Set(LoRACatalogSettings.enabledIDList(for: modelKey, lc: lc, draftByModel: draftByModel))
        if enabled.contains(loraID) { return "active" }
        if LoRAPathResolver.localWeightsPath(loraID: loraID, entry: getEntry(loraID: loraID, lc: lc)) != nil {
            return "installed"
        }
        return "uninstalled"
    }

    static func probeStateForModel(
        entry: LoRAEntry,
        modelKey: String,
        lc: [String: Any]
    ) -> String {
        let ms = LoRACatalogSettings.modelSupportDict(lc)
        if LoRAModelRegistry.probeSupportedOnModel(entry: entry, modelKey: modelKey, modelSupport: ms) {
            return "pass"
        }
        if ms[entry.loraID] != nil { return "fail" }
        return "unknown"
    }
}
