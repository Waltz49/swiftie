import Foundation

/// EXIF LoRA name → catalog ids (port of `match_exif_lora_names_to_ids_and_scales`).
enum LoRAExifMatch {
    private static let weightSuffixRE: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"\s*\[([0-9]+(?:\.[0-9]+)?)\]\s*$"#)
    }()

    static func match(
        loraText: String,
        plugin: ImageGenPluginDescriptor,
        lc: [String: Any]
    ) -> (ids: [String], scalesByID: [String: Double]) {
        let target = loraText.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.isEmpty || target.lowercased() == "none" { return ([], [:]) }
        let modelKey = plugin.hfModelID
        let ms = LoRACatalogSettings.modelSupportDict(lc)
        var parts = target.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if parts.count <= 1 { parts = [target] }

        var matchedIDs: [String] = []
        var scales: [String: Double] = [:]
        for part in parts {
            let (name, weight) = parseNameAndWeight(part)
            let token = normalizeToken(name.isEmpty ? part : name)
            if token.isEmpty { continue }
            var foundID: String?
            var modelMatchID: String?
            for entry in LoRACatalog.catalogEntriesSorted(lc: lc) {
                guard LoRACatalog.isInstalled(entry: entry) else { continue }
                if !matchKeys(entry: entry, modelKey: modelKey).contains(token) { continue }
                if LoRAModelRegistry.entryMatchesModel(entry, modelKey: modelKey, modelSupport: ms)
                    || (LoRAEntry.isUserLoraID(entry.loraID)
                        && LoRAModelRegistry.hostID(forModelKey: modelKey) == entry.hostID) {
                    foundID = entry.loraID
                    break
                }
                if modelMatchID == nil { modelMatchID = entry.loraID }
            }
            let resolved = foundID ?? modelMatchID
            guard let id = resolved, !matchedIDs.contains(id) else { continue }
            matchedIDs.append(id)
            if let weight { scales[id] = weight }
        }
        return (matchedIDs, scales)
    }

    static func parseNameAndWeight(_ part: String) -> (String, Double?) {
        let text = part.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return ("", nil) }
        guard let re = weightSuffixRE else { return (text, nil) }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = re.firstMatch(in: text, range: range), match.numberOfRanges >= 2 else {
            return (text, nil)
        }
        let nameRange = NSRange(location: 0, length: match.range.location)
        let name = ns.substring(with: nameRange).trimmingCharacters(in: .whitespacesAndNewlines)
        let weightRange = match.range(at: 1)
        let weightStr = ns.substring(with: weightRange)
        guard let weight = Double(weightStr) else { return (name.isEmpty ? text : name, nil) }
        return (name.isEmpty ? text : name, weight)
    }

    private static func normalizeToken(_ name: String) -> String {
        let stripped = parseNameAndWeight(name).0
        return stripped.lowercased()
    }

    private static func matchKeys(entry: LoRAEntry, modelKey: String) -> Set<String> {
        var keys: Set<String> = []
        for raw in [entry.displayName, LoRACatalog.baseDisplayName(entry: entry, modelKey: modelKey), entry.loraID] {
            let t = normalizeToken(raw)
            if !t.isEmpty { keys.insert(t) }
        }
        let repo = entry.repoID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !repo.isEmpty {
            keys.insert(normalizeToken(repo))
            if let last = repo.split(separator: "/").last {
                keys.insert(normalizeToken(String(last)))
            }
        }
        let filename = entry.filename.trimmingCharacters(in: .whitespacesAndNewlines)
        if !filename.isEmpty {
            let stem = (filename as NSString).deletingPathExtension
            let t = normalizeToken(stem)
            if !t.isEmpty { keys.insert(t) }
        }
        return keys
    }
}
