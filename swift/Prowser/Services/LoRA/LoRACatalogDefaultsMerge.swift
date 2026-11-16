import Foundation

/// Merge bundled defaults into an existing ``lora_catalog.json`` (existing LoRA IDs win).
enum LoRACatalogDefaultsMerge {
    struct Result: Equatable, Sendable {
        var entriesAdded: Int
        var entriesSkippedExisting: Int
        var enabledIDsAdded: Int
        var deletedIDsAdded: Int
        var modelsTouched: Set<String>
        var logLines: [String]

        var summaryText: String {
            logLines.joined(separator: "\n")
        }
    }

    static func merge(existing: [String: Any], imported: [String: Any]) -> (catalog: [String: Any], result: Result) {
        var base = LoRACatalogSettings.migrateCatalog(existing)
        let incoming = LoRACatalogSettings.migrateCatalog(imported)

        var logLines: [String] = []
        var entriesAdded = 0
        var entriesSkipped = 0
        var enabledAdded = 0
        var deletedAdded = 0
        var modelsTouched = Set<String>()

        let existingIDs = userEntryIDs(in: base)
        let importedIDs = userEntryIDs(in: incoming)
        let newIDs = importedIDs.subtracting(existingIDs)

        base = mergeUserEntries(into: base, from: incoming, newIDs: newIDs, added: &entriesAdded, skipped: &entriesSkipped)
        base = mergeIDKeyedDict(
            key: LoRACatalogSettings.entryOverridesKey,
            into: &base,
            from: incoming,
            existingIDs: existingIDs
        )
        base = mergeIDKeyedDict(key: "model_support", into: &base, from: incoming, existingIDs: existingIDs)
        base = mergeIDKeyedDict(
            key: LoRACatalogSettings.crossFamilyModelsKey,
            into: &base,
            from: incoming,
            existingIDs: existingIDs
        )

        for key in [LoRACatalogSettings.byHostKey, LoRACatalogSettings.byModelKey] {
            let (merged, stats) = mergeSlices(
                into: base[key] as? [String: Any] ?? [:],
                from: incoming[key] as? [String: Any] ?? [:],
                newIDs: newIDs,
                existingIDs: existingIDs
            )
            base[key] = merged
            enabledAdded += stats.enabledAdded
            deletedAdded += stats.deletedAdded
            modelsTouched.formUnion(stats.modelKeys)
        }
        if enabledAdded > 0 || deletedAdded > 0 {
            logLines.append("List updates: \(enabledAdded) enabled slots, \(deletedAdded) deleted slots (new LoRAs only).")
        }

        logLines.insert("Added \(entriesAdded) LoRA catalog entries (\(entriesSkipped) already present, skipped).", at: 0)
        if newIDs.isEmpty {
            logLines.append("No new LoRA IDs in the defaults blob.")
        } else {
            logLines.append("New IDs:")
            for lid in newIDs.sorted() {
                logLines.append("  \(lid)")
            }
        }

        let result = Result(
            entriesAdded: entriesAdded,
            entriesSkippedExisting: entriesSkipped,
            enabledIDsAdded: enabledAdded,
            deletedIDsAdded: deletedAdded,
            modelsTouched: modelsTouched,
            logLines: logLines
        )
        return (LoRACatalogSettings.migrateCatalog(base), result)
    }

    private static func userEntryIDs(in lc: [String: Any]) -> Set<String> {
        guard let raw = lc[LoRACatalogSettings.userEntriesKey] as? [String: Any] else { return [] }
        return Set(raw.keys.map { String($0) })
    }

    private static func mergeUserEntries(
        into base: [String: Any],
        from incoming: [String: Any],
        newIDs: Set<String>,
        added: inout Int,
        skipped: inout Int
    ) -> [String: Any] {
        var out = base
        var users = (out[LoRACatalogSettings.userEntriesKey] as? [String: Any]) ?? [:]
        let imported = (incoming[LoRACatalogSettings.userEntriesKey] as? [String: Any]) ?? [:]

        for (lid, blob) in imported {
            guard let dict = blob as? [String: Any] else { continue }
            if users[lid] != nil {
                skipped += 1
                continue
            }
            guard newIDs.contains(lid) else { continue }
            users[lid] = dict
            added += 1
        }
        out[LoRACatalogSettings.userEntriesKey] = users
        return out
    }

    private static func mergeIDKeyedDict(
        key: String,
        into base: inout [String: Any],
        from incoming: [String: Any],
        existingIDs: Set<String>
    ) -> [String: Any] {
        var target = (base[key] as? [String: Any]) ?? [:]
        let source = (incoming[key] as? [String: Any]) ?? [:]
        for (lid, value) in source {
            if existingIDs.contains(lid) { continue }
            if target[lid] == nil {
                target[lid] = value
            }
        }
        if !target.isEmpty {
            base[key] = target
        }
        return base
    }

    private struct SliceMergeStats {
        var enabledAdded: Int
        var deletedAdded: Int
        var modelKeys: Set<String>
    }

    private static func mergeSlices(
        into base: [String: Any],
        from incoming: [String: Any],
        newIDs: Set<String>,
        existingIDs: Set<String>
    ) -> (merged: [String: Any], stats: SliceMergeStats) {
        var out = base
        var stats = SliceMergeStats(enabledAdded: 0, deletedAdded: 0, modelKeys: [])
        let allKeys = Set(base.keys).union(incoming.keys)
        for modelKey in allKeys {
            var slice = (out[modelKey] as? [String: Any]) ?? ["enabled_ids": [], LoRACatalogSettings.deletedIDsKey: []]
            let importedSlice = (incoming[modelKey] as? [String: Any]) ?? [:]
            let beforeEnabled = Set((slice["enabled_ids"] as? [String]) ?? [])
            let beforeDeleted = Set(deletedList(from: slice))

            var enabled = (slice["enabled_ids"] as? [String]) ?? []
            var deleted = deletedList(from: slice)

            for lid in (importedSlice["enabled_ids"] as? [String]) ?? [] {
                guard newIDs.contains(lid), !existingIDs.contains(lid) else { continue }
                if !enabled.contains(lid) {
                    enabled.append(lid)
                    stats.enabledAdded += 1
                    stats.modelKeys.insert(modelKey)
                }
            }
            for lid in deletedList(from: importedSlice) {
                guard newIDs.contains(lid), !existingIDs.contains(lid) else { continue }
                if !deleted.contains(lid) {
                    deleted.append(lid)
                    stats.deletedAdded += 1
                    stats.modelKeys.insert(modelKey)
                }
            }

            let afterEnabled = Set(enabled)
            let afterDeleted = Set(deleted)
            if afterEnabled != beforeEnabled || afterDeleted != beforeDeleted {
                slice["enabled_ids"] = enabled
                slice[LoRACatalogSettings.deletedIDsKey] = deleted
                out[modelKey] = slice
            }
        }
        return (out, stats)
    }

    private static func deletedList(from slice: [String: Any]) -> [String] {
        if let deleted = slice[LoRACatalogSettings.deletedIDsKey] as? [String], !deleted.isEmpty {
            return deleted
        }
        return (slice[LoRACatalogSettings.legacyHiddenKey] as? [String]) ?? []
    }
}