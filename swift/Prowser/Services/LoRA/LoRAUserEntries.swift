import Foundation

enum LoRAUserEntries {
    static func entries(from lc: [String: Any]) -> [String: LoRAEntry] {
        guard let raw = lc[LoRACatalogSettings.userEntriesKey] as? [String: Any] else { return [:] }
        var out: [String: LoRAEntry] = [:]
        for (lid, value) in raw {
            guard let dict = value as? [String: Any],
                  let entry = LoRAEntry.fromDictionary(dict),
                  LoRAEntry.isUserLoraID(entry.loraID) else { continue }
            out[lid] = entry
        }
        return out
    }

    static func mergedCatalog(lc: [String: Any]) -> [String: LoRAEntry] {
        entries(from: lc)
    }

    /// Alias for catalog facade.
    static func mergedCatalog(from lc: [String: Any]) -> [String: LoRAEntry] {
        mergedCatalog(lc: lc)
    }

    static func displayName(from path: URL) -> String {
        let name = path.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Imported LoRA" : name
    }

    static func slugify(_ name: String) -> String {
        let lowered = name.lowercased()
        let allowed = lowered.unicodeScalars.map { scalar -> String in
            if CharacterSet.alphanumerics.contains(scalar) { return String(scalar) }
            return "_"
        }.joined()
        return allowed.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    static func uniqueLoraID(base: String, existing: [String: LoRAEntry]) -> String {
        var candidate = LoRAEntry.userIDPrefix + base
        if existing[candidate] == nil { return candidate }
        var n = 2
        while existing["\(LoRAEntry.userIDPrefix)\(base)_\(n)"] != nil { n += 1 }
        return "\(LoRAEntry.userIDPrefix)\(base)_\(n)"
    }

    static func copyToUserCache(source: URL, loraID: String) throws -> URL {
        let destDir = LoRACachePaths.userCacheRoot.appendingPathComponent(loraID, isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent(source.lastPathComponent)
        let src = source.standardizedFileURL
        if src == dest.standardizedFileURL { return dest }
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)
        return dest
    }
}
