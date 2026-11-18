import Foundation

/// Disk-touching catalog upkeep (path repair, dedupe, enabled pruning). Not for load/save hot paths.
enum LoRACatalogMaintenance {
    static func runDiskMaintenance(in lc: inout [String: Any]) -> Bool {
        let before = LoRACatalogSettings.canonicalJSONFingerprint(lc)
        _ = LoRACatalogPathRepair.repairUserEntryPaths(in: &lc)
        if (lc[LoRACatalogSettings.catalogDedupeMergedKey] as? Bool) != true {
            _ = LoRACatalogDedupe.mergeDuplicateUserEntries(in: &lc, includeDiscoverFallback: true)
            lc[LoRACatalogSettings.catalogDedupeMergedKey] = true
        }
        _ = LoRACatalogPathRepair.pruneUninstalledEnabledIDs(in: &lc)
        let after = LoRACatalogSettings.canonicalJSONFingerprint(lc)
        return before != after
    }
}