import Foundation

/// Refresh stale ``local_path`` values in ``lora_catalog.json`` when weights moved to user cache.
enum LoRACatalogPathRepair {
    /// Update ``user_entries`` paths when weights are found on disk. Returns number of entries updated.
    static func repairUserEntryPaths(in lc: inout [String: Any]) -> Int {
        guard var raw = lc[LoRACatalogSettings.userEntriesKey] as? [String: Any] else { return 0 }
        var fixes = 0
        for (lid, value) in raw {
            guard var dict = value as? [String: Any] else { continue }
            guard let entry = LoRAEntry.fromDictionary(dict) else { continue }
            let url = LoRAPathResolver.fastLocalWeightsPath(loraID: lid, entry: entry)
                ?? LoRAPathResolver.discoverLocalWeightsPath(loraID: lid, entry: entry)
            guard let url else { continue }
            let path = url.path
            let previous = (dict["local_path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if previous == path { continue }
            dict["local_path"] = path
            let leaf = url.lastPathComponent
            let existingFilename = entry.filename.trimmingCharacters(in: .whitespacesAndNewlines)
            if !leaf.isEmpty, existingFilename != leaf, existingFilename.isEmpty || !FileManager.default.fileExists(atPath: previous) {
                dict["filename"] = leaf
            }
            raw[lid] = dict
            fixes += 1
        }
        if fixes > 0 {
            lc[LoRACatalogSettings.userEntriesKey] = raw
        }
        return fixes
    }

    /// Drop ``enabled_ids`` entries with no weights on disk so Settings checkboxes stay honest.
    static func pruneUninstalledEnabledIDs(in lc: inout [String: Any]) -> Int {
        let catalog = LoRACatalog.mergedCatalog(lc: lc)
        var byModel = lc[LoRACatalogSettings.byModelKey] as? [String: Any] ?? [:]
        var dropped = 0
        for (modelKey, raw) in byModel {
            guard var slice = raw as? [String: Any] else { continue }
            let enabled = (slice["enabled_ids"] as? [String]) ?? []
            let kept = enabled.filter { lid in
                guard let entry = catalog[lid] else { return false }
                return LoRAPathResolver.localWeightsPath(loraID: lid, entry: entry) != nil
            }
            dropped += enabled.count - kept.count
            if kept.count != enabled.count {
                slice["enabled_ids"] = kept
                byModel[modelKey] = slice
            }
        }
        if dropped > 0 {
            lc[LoRACatalogSettings.byModelKey] = byModel
        }
        return dropped
    }
}