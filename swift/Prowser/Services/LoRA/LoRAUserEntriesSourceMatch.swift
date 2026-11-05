import Foundation

extension LoRAUserEntries {
    private static func standardizedFileURL(_ url: URL) -> URL {
        URL(fileURLWithPath: (url.path as NSString).expandingTildeInPath).standardizedFileURL
    }

    static func sameLoraFile(_ a: URL, _ b: URL) -> Bool {
        let aExpanded = standardizedFileURL(a)
        let bExpanded = standardizedFileURL(b)
        if aExpanded == bExpanded { return true }
        if sameFileResourceIdentifier(aExpanded, bExpanded) { return true }
        return false
    }

    private static func sameFileResourceIdentifier(_ a: URL, _ b: URL) -> Bool {
        guard let aID = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let bID = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        else {
            return false
        }
        return (aID as AnyObject).isEqual(bID as AnyObject)
    }

    static func entryPathCandidates(_ entry: LoRAEntry) -> [URL] {
        var paths: [URL] = []
        for raw in [entry.localPath, entry.sourcePath] {
            let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://") {
                continue
            }
            paths.append(URL(fileURLWithPath: (text as NSString).expandingTildeInPath))
        }
        return paths
    }

    static func findUserLoraForSource(
        path: URL,
        hostID: String,
        entries: [String: LoRAEntry]
    ) -> LoRAEntry? {
        let host = hostID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        let source = standardizedFileURL(path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        for entry in entries.values where entry.hostID == host {
            for candidate in entryPathCandidates(entry) where sameLoraFile(source, candidate) {
                return entry
            }
        }
        return nil
    }
}
