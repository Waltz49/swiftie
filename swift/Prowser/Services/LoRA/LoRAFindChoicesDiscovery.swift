import Foundation

/// On-disk LoRA listing for Add LoRA → Find (Python ``discover_find_lora_choices`` parity).
enum LoRAFindChoicesDiscovery {
    struct Choice: Equatable, Sendable {
        var key: String
        var displayName: String
        var weightsPath: String
        var triggerWord: String
        var fromDownloads: Bool
    }

    static func discover(lc: [String: Any], profilePaths: ProfilePaths) -> [Choice] {
        var choices: [Choice] = []
        var plannedPaths = Set<String>()
        var seenKeys = Set<String>()
        var seenNameSize = Set<String>()

        func rememberNameSize(name: String, url: URL) -> Bool {
            let text = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !text.isEmpty else { return true }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let token = "\(text)\0\(size)"
            if seenNameSize.contains(token) { return false }
            seenNameSize.insert(token)
            return true
        }

        let registeredPaths = registeredWeightPaths(lc: lc)

        for entry in LoRACatalog.catalogEntriesSorted(lc: lc) {
            if entry.mfluxCompatible == false { continue }
            guard let url = LoRAPathResolver.localWeightsPath(loraID: entry.loraID, entry: entry) else { continue }
            let path = url.path
            plannedPaths.insert(path)
            let key = entry.loraID
            if seenKeys.contains(key) { continue }
            let name = entry.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let display = name.isEmpty ? LoRAUserEntries.displayName(from: url) : name
            if !rememberNameSize(name: display, url: url) { continue }
            seenKeys.insert(key)
            let trigger = entry.triggerWord?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            choices.append(
                Choice(
                    key: key,
                    displayName: display,
                    weightsPath: path,
                    triggerWord: trigger,
                    fromDownloads: false
                )
            )
        }

        for url in enumerateWeightFiles(profilePaths: profilePaths) {
            let path = url.path
            if plannedPaths.contains(path) { continue }
            if registeredPaths.contains(path) { continue }
            let key = "path:\(path)"
            if seenKeys.contains(key) { continue }
            let display = LoRAUserEntries.displayName(from: url)
            if !rememberNameSize(name: display, url: url) { continue }
            seenKeys.insert(key)
            let fromDownloads = isTopLevelDownloads(url)
            choices.append(
                Choice(
                    key: key,
                    displayName: display,
                    weightsPath: path,
                    triggerWord: "",
                    fromDownloads: fromDownloads
                )
            )
        }

        return choices.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    static func bridgeDictionaries(from choices: [Choice]) -> [[String: Any]] {
        choices.map { choice in
            [
                "key": choice.key,
                "display_name": choice.displayName,
                "weights_path": choice.weightsPath,
                "trigger_word": choice.triggerWord,
                "from_downloads": choice.fromDownloads,
            ]
        }
    }

    private static func searchRoots(profilePaths: ProfilePaths) -> [URL] {
        [
            LoRACachePaths.defaultCache,
            LoRACachePaths.altCache,
            profilePaths.cacheDirectory.appendingPathComponent("loras", isDirectory: true),
        ]
    }

    private static func enumerateWeightFiles(profilePaths: ProfilePaths) -> [URL] {
        var out: [URL] = []
        var seen = Set<String>()
        for root in searchRoots(profilePaths: profilePaths) {
            for url in cacheSafetensors(under: root) {
                let path = url.path
                if seen.contains(path) { continue }
                seen.insert(path)
                out.append(url)
            }
        }
        for url in downloadsSafetensors() {
            let path = url.path
            if seen.contains(path) { continue }
            seen.insert(path)
            out.append(url)
        }
        return out
    }

    private static func cacheSafetensors(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var paths: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "safetensors" else { continue }
            guard LoRAPathResolver.weightsFileIsValid(url) else { continue }
            paths.append(url.standardizedFileURL)
        }
        return paths.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private static func downloadsSafetensors() -> [URL] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return children
            .filter { $0.pathExtension.lowercased() == "safetensors" }
            .filter { LoRAPathResolver.weightsFileIsValid($0) }
            .map(\.standardizedFileURL)
            .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private static func isTopLevelDownloads(_ url: URL) -> Bool {
        let downloads = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
            .standardizedFileURL
        return url.deletingLastPathComponent().standardizedFileURL == downloads
    }

    private static func registeredWeightPaths(lc: [String: Any]) -> Set<String> {
        var paths = Set<String>()
        for entry in LoRACatalog.catalogEntriesSorted(lc: lc) {
            if let local = entry.localPath, !local.isEmpty {
                paths.insert(URL(fileURLWithPath: (local as NSString).expandingTildeInPath).standardizedFileURL.path)
            }
            if let source = entry.sourcePath, !source.isEmpty {
                paths.insert(URL(fileURLWithPath: (source as NSString).expandingTildeInPath).standardizedFileURL.path)
            }
            if let weights = LoRAPathResolver.localWeightsPath(loraID: entry.loraID, entry: entry) {
                paths.insert(weights.path)
            }
        }
        return paths
    }
}
