import Foundation

/// Settings/catalog dedupe when multiple LoRA ids refer to the same weights file (port of `lora_catalog.py`).
enum LoRACatalogDedupe {
    static func preferSettingsCatalogEntry(
        _ left: LoRAEntry,
        _ right: LoRAEntry,
        lc: [String: Any]
    ) -> LoRAEntry {
        let support = LoRACatalogSettings.modelSupportDict(lc)
        func score(_ entry: LoRAEntry) -> (Int, Bool, Int, String) {
            let models = support[entry.loraID]?.count ?? 0
            let installed = !LoRAWeightsIdentity.catalogPathCandidates(entry: entry).isEmpty
            let suffixPenalty: Int
            if LoRAEntry.isUserLoraID(entry.loraID),
               entry.loraID.range(of: #"_\d+$"#, options: .regularExpression) != nil {
                suffixPenalty = 1
            } else {
                suffixPenalty = 0
            }
            return (models, installed, -suffixPenalty, entry.loraID)
        }
        let leftScore = score(left)
        let rightScore = score(right)
        if leftScore.0 != rightScore.0 { return leftScore.0 > rightScore.0 ? left : right }
        if leftScore.1 != rightScore.1 { return leftScore.1 ? left : right }
        if leftScore.2 != rightScore.2 { return leftScore.2 > rightScore.2 ? left : right }
        return leftScore.3 >= rightScore.3 ? left : right
    }

    static func mergeDisplayMetadata(preferred: LoRAEntry, other: LoRAEntry) -> LoRAEntry {
        var entry = preferred
        func isEmpty(_ text: String?) -> Bool {
            text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        }
        if isEmpty(entry.triggerWord), let t = other.triggerWord, !isEmpty(t) {
            entry.triggerWord = t
        }
        if isEmpty(entry.comment), let c = other.comment, !isEmpty(c) {
            entry.comment = c
        }
        if isEmpty(entry.referencePrompt), let r = other.referencePrompt, !isEmpty(r) {
            entry.referencePrompt = r
        }
        if isEmpty(entry.webPageURL), let u = other.webPageURL, !isEmpty(u) {
            entry.webPageURL = u
        }
        if LoRAWeightsIdentity.catalogPathCandidates(entry: entry).isEmpty {
            for url in LoRAWeightsIdentity.catalogPathCandidates(entry: other) {
                entry.localPath = url.path
                break
            }
        }
        return entry
    }

    /// One row per on-disk weights file (catalog maintenance / tests; not used on Settings tab open).
    static func dedupeSettingsEntriesByWeights(
        _ entries: [LoRAEntry],
        lc: [String: Any]
    ) -> [LoRAEntry] {
        guard entries.count > 1 else { return entries }
        var comparePaths: [URL] = []
        for entry in entries {
            comparePaths.append(contentsOf: LoRAWeightsIdentity.catalogPathCandidates(entry: entry))
        }
        let hashSizes = LoRAWeightsIdentity.sizeConflictSet(paths: comparePaths)
        var digestCache: LoRAWeightsIdentity.DigestCache = [:]
        var order: [String] = []
        var best: [String: LoRAEntry] = [:]
        for entry in entries {
            let key = LoRAWeightsIdentity.entryWeightsIdentityKey(
                loraID: entry.loraID,
                entry: entry,
                digestCache: &digestCache,
                hashSizes: hashSizes
            )
            if let existing = best[key] {
                let preferred = preferSettingsCatalogEntry(existing, entry, lc: lc)
                let other = preferred.loraID == existing.loraID ? entry : existing
                best[key] = mergeDisplayMetadata(preferred: preferred, other: other)
            } else {
                best[key] = entry
                order.append(key)
            }
        }
        return order.map { best[$0]! }
    }

    /// Collapse duplicate user catalog records so enabled ids and probe state stay on the surviving row.
    static func mergeDuplicateUserEntries(in lc: inout [String: Any], includeDiscoverFallback: Bool = false) -> Int {
        let catalog = LoRACatalog.mergedCatalog(lc: lc)
        let userIDs = catalog.keys.filter { LoRAEntry.isUserLoraID($0) }
        guard userIDs.count > 1 else { return 0 }

        var comparePaths: [URL] = []
        for lid in userIDs {
            guard let entry = catalog[lid] else { continue }
            comparePaths.append(
                contentsOf: LoRAWeightsIdentity.entryPathCandidates(
                    loraID: lid,
                    entry: entry,
                    includeDiscoverFallback: includeDiscoverFallback
                )
            )
        }
        let hashSizes = LoRAWeightsIdentity.sizeConflictSet(paths: comparePaths)
        var digestCache: LoRAWeightsIdentity.DigestCache = [:]
        var groups: [String: [String]] = [:]
        for lid in userIDs {
            guard let entry = catalog[lid] else { continue }
            let key = LoRAWeightsIdentity.entryWeightsIdentityKey(
                loraID: lid,
                entry: entry,
                digestCache: &digestCache,
                hashSizes: hashSizes,
                includeDiscoverFallback: includeDiscoverFallback
            )
            groups[key, default: []].append(lid)
        }

        var merges = 0
        for ids in groups.values where ids.count > 1 {
            let entries = ids.compactMap { catalog[$0] }
            guard entries.count > 1 else { continue }
            var winner = entries[0]
            for other in entries.dropFirst() {
                winner = preferSettingsCatalogEntry(winner, other, lc: lc)
            }
            let winnerID = winner.loraID
            let losers = ids.filter { $0 != winnerID }
            for loserID in losers {
                mergeCatalogRecord(winnerID: winnerID, loserID: loserID, in: &lc)
                merges += 1
            }
        }
        return merges
    }

    private static func mergeCatalogRecord(winnerID: String, loserID: String, in lc: inout [String: Any]) {
        guard winnerID != loserID else { return }
        let catalog = LoRACatalog.mergedCatalog(lc: lc)
        guard let winner = catalog[winnerID], let loser = catalog[loserID] else { return }
        let merged = mergeDisplayMetadata(preferred: winner, other: loser)

        if var raw = lc[LoRACatalogSettings.userEntriesKey] as? [String: Any] {
            let winnerRaw = raw[winnerID] as? [String: Any] ?? [:]
            raw[winnerID] = LoRAEntry.mergedUserEntryDictionary(entry: merged, preserving: winnerRaw)
            raw.removeValue(forKey: loserID)
            lc[LoRACatalogSettings.userEntriesKey] = raw
        }

        if var ms = lc["model_support"] as? [String: Any] {
            let winnerModels = Set((ms[winnerID] as? [String]) ?? [])
            let loserModels = (ms[loserID] as? [String]) ?? []
            ms[winnerID] = Array(winnerModels.union(loserModels)).sorted()
            ms.removeValue(forKey: loserID)
            lc["model_support"] = ms
        }

        if var overrides = lc[LoRACatalogSettings.entryOverridesKey] as? [String: Any] {
            let winnerO = overrides[winnerID] as? [String: Any] ?? [:]
            let loserO = overrides[loserID] as? [String: Any] ?? [:]
            if !loserO.isEmpty {
                var combined = loserO
                for (key, value) in winnerO {
                    combined[key] = combined[key] ?? value
                }
                overrides[winnerID] = combined
            }
            overrides.removeValue(forKey: loserID)
            lc[LoRACatalogSettings.entryOverridesKey] = overrides
        }

        if var cfm = lc[LoRACatalogSettings.crossFamilyModelsKey] as? [String: Any] {
            if let loserList = cfm[loserID] as? [String] {
                var winnerList = (cfm[winnerID] as? [String]) ?? []
                winnerList.append(contentsOf: loserList)
                cfm[winnerID] = Array(Set(winnerList))
            }
            cfm.removeValue(forKey: loserID)
            lc[LoRACatalogSettings.crossFamilyModelsKey] = cfm
        }

        if var ph = lc[LoRACatalogSettings.probeHistoryKey] as? [String: Any] {
            if let loserHist = ph[loserID] {
                if ph[winnerID] == nil {
                    ph[winnerID] = loserHist
                }
                ph.removeValue(forKey: loserID)
                lc[LoRACatalogSettings.probeHistoryKey] = ph
            }
        }

        if var byModel = lc[LoRACatalogSettings.byModelKey] as? [String: Any] {
            for (modelKey, value) in byModel {
                guard var slice = value as? [String: Any] else { continue }
                var enabled = (slice["enabled_ids"] as? [String]) ?? []
                let hadLoser = enabled.contains(loserID)
                enabled.removeAll { $0 == loserID }
                if hadLoser, !enabled.contains(winnerID) {
                    enabled.append(winnerID)
                }
                slice["enabled_ids"] = enabled

                var deleted = (slice[LoRACatalogSettings.deletedIDsKey] as? [String])
                    ?? (slice[LoRACatalogSettings.legacyHiddenKey] as? [String])
                    ?? []
                deleted.removeAll { $0 == loserID }
                slice[LoRACatalogSettings.deletedIDsKey] = deleted
                byModel[modelKey] = slice
            }
            lc[LoRACatalogSettings.byModelKey] = byModel
        }

        if var byHost = lc[LoRACatalogSettings.byHostKey] as? [String: Any] {
            for (hostID, value) in byHost {
                guard var slice = value as? [String: Any] else { continue }
                var enabled = (slice["enabled_ids"] as? [String]) ?? []
                let hadLoser = enabled.contains(loserID)
                enabled.removeAll { $0 == loserID }
                if hadLoser, !enabled.contains(winnerID) {
                    enabled.append(winnerID)
                }
                slice["enabled_ids"] = enabled
                byHost[hostID] = slice
            }
            lc[LoRACatalogSettings.byHostKey] = byHost
        }
    }
}