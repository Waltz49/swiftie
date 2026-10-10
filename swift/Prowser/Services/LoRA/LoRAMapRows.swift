import Foundation

/// LoRA map debug rows (port of `run_lora_map.py`).
enum LoRAMapRows {
    struct Row {
        var loraID: String
        var loraLabel: String
        var models: [(label: String, crossFamily: Bool)]
    }

    static func rows(lc: [String: Any]) -> [Row] {
        let ms = LoRACatalogSettings.modelSupportDict(lc)
        let crossRaw = lc[LoRACatalogSettings.crossFamilyModelsKey] as? [String: Any] ?? [:]
        var out: [Row] = []
        for entry in LoRACatalog.catalogEntriesSorted(lc: lc) {
            guard LoRAPathResolver.localWeightsPath(loraID: entry.loraID, entry: entry) != nil else { continue }
            let label = entry.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let display = label.isEmpty ? entry.loraID : label
            var models: [(String, Bool)] = []
            for mk in LoRAHFModelIDs.probeModelOrder {
                guard LoRACatalog.probePassed(
                    loraID: entry.loraID,
                    modelKey: mk,
                    entry: entry,
                    modelSupport: ms
                ) else { continue }
                var modelLabel = LoRAHFModelIDs.displayName(for: mk)
                let isCross = LoRACatalog.crossFamily(entry: entry, loraID: entry.loraID, modelKey: mk, lc: lc)
                    || ((crossRaw[entry.loraID] as? [String])?.contains(mk) == true)
                if isCross { modelLabel += " *" }
                models.append((modelLabel, isCross))
            }
            out.append(Row(loraID: entry.loraID, loraLabel: display, models: models))
        }
        return out.sorted { $0.loraLabel.lowercased() < $1.loraLabel.lowercased() }
    }
}
