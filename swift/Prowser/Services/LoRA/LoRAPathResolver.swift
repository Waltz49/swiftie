import Foundation

enum LoRAPathResolver {
    static func catalogCachePath(entry: LoRAEntry) -> URL? {
        if let local = entry.localPath, !local.isEmpty {
            return URL(fileURLWithPath: (local as NSString).expandingTildeInPath)
        }
        guard !entry.repoID.isEmpty, !entry.filename.isEmpty else { return nil }
        let dir = LoRACachePaths.defaultCache
            .appendingPathComponent(entry.repoID.replacingOccurrences(of: "/", with: "__"), isDirectory: true)
        return dir.appendingPathComponent(entry.filename)
    }

    /// Stat-only check for settings lists and dedupe keys (no file open).
    static func weightsLikelyOnDisk(at path: URL) -> Bool {
        let resolved = URL(fileURLWithPath: (path.path as NSString).expandingTildeInPath).standardizedFileURL
        guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size >= 1024 else { return false }
        return true
    }

    static func weightsFileIsValid(_ path: URL) -> Bool {
        guard weightsLikelyOnDisk(at: path) else { return false }
        if path.pathExtension.lowercased() != "safetensors" { return true }
        guard let handle = try? FileHandle(forReadingFrom: path) else { return false }
        defer { try? handle.close() }
        let prefix = handle.readData(ofLength: 8)
        return prefix.count >= 8
    }

    static func localWeightsPath(loraID: String, entry: LoRAEntry?) -> URL? {
        discoverLocalWeightsPath(loraID: loraID, entry: entry)
    }

    /// Settings / catalog grid: Python ``local_lora_weights_path`` (no hub tree walk).
    static func fastLocalWeightsPath(loraID: String, entry: LoRAEntry?) -> URL? {
        guard let entry else { return nil }
        if let local = entry.localPath, !local.isEmpty {
            let url = URL(fileURLWithPath: (local as NSString).expandingTildeInPath)
            if weightsLikelyOnDisk(at: url) { return url.standardizedFileURL }
        }
        if let cache = catalogCachePath(entry: entry), weightsLikelyOnDisk(at: cache) {
            return cache.standardizedFileURL
        }
        if LoRAEntry.isUserLoraID(loraID) {
            let dir = LoRACachePaths.userCacheRoot.appendingPathComponent(loraID, isDirectory: true)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
            for name in names.filter({ $0.lowercased().hasSuffix(".safetensors") }).sorted() {
                let url = dir.appendingPathComponent(name)
                if weightsLikelyOnDisk(at: url) { return url.standardizedFileURL }
            }
        }
        return nil
    }

    /// Find on-disk weights without downloading (includes fallbacks for stale ``local_path``).
    static func discoverLocalWeightsPath(loraID: String, entry: LoRAEntry?) -> URL? {
        guard let entry else { return nil }
        if let local = entry.localPath, !local.isEmpty {
            let url = URL(fileURLWithPath: (local as NSString).expandingTildeInPath)
            if weightsFileIsValid(url) { return url.standardizedFileURL }
        }
        if !entry.repoID.isEmpty, !entry.filename.isEmpty {
            let repoKey = entry.repoID.replacingOccurrences(of: "/", with: "__")
            for cacheRoot in [LoRACachePaths.defaultCache, LoRACachePaths.altCache] {
                let dir = cacheRoot.appendingPathComponent(repoKey, isDirectory: true)
                let hub = dir.appendingPathComponent(entry.filename)
                if weightsFileIsValid(hub) { return hub.standardizedFileURL }
                if let found = hubRepoWeightsPath(repoRoot: dir, preferredFilename: entry.filename) {
                    return found
                }
            }
        }
        if LoRAEntry.isUserLoraID(loraID) {
            if let userCache = userCacheWeightsPath(loraID: loraID) { return userCache }
            if let prefixed = userCacheWeightsPathByIDPrefix(loraID: loraID) { return prefixed }
        }
        return nil
    }

    private static func hubRepoWeightsPath(repoRoot: URL, preferredFilename: String) -> URL? {
        guard FileManager.default.fileExists(atPath: repoRoot.path) else { return nil }
        let preferredLeaf = (preferredFilename as NSString).lastPathComponent.lowercased()
        var files: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: repoRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "safetensors" else { continue }
            guard weightsFileIsValid(url) else { continue }
            files.append(url.standardizedFileURL)
        }
        guard !files.isEmpty else { return nil }
        if !preferredLeaf.isEmpty, let match = files.first(where: { $0.lastPathComponent.lowercased() == preferredLeaf }) {
            return match
        }
        return files.count == 1 ? files[0] : nil
    }

    /// ``…/mflux_loras/user/<lora_id>/`` when ``local_path`` in the catalog is stale.
    private static func userCacheWeightsPath(loraID: String) -> URL? {
        let dir = LoRACachePaths.userCacheRoot.appendingPathComponent(loraID, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let sorted = names.filter { $0.lowercased().hasSuffix(".safetensors") }.sorted()
        for name in sorted {
            let url = dir.appendingPathComponent(name)
            if weightsFileIsValid(url) { return url.standardizedFileURL }
        }
        return nil
    }

    /// ``user_<id>_…/`` sibling folders after dedupe imports.
    private static func userCacheWeightsPathByIDPrefix(loraID: String) -> URL? {
        let root = LoRACachePaths.userCacheRoot
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return nil }
        var matches: [URL] = []
        for name in names.sorted() {
            guard name == loraID || name.hasPrefix("\(loraID)_") else { continue }
            let dir = root.appendingPathComponent(name, isDirectory: true)
            if let url = userCacheWeightsPath(loraID: name) {
                matches.append(url)
            } else if let picked = pickWeights(inUserDirectory: dir) {
                matches.append(picked)
            }
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private static func pickWeights(inUserDirectory dir: URL) -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let sorted = names.filter { $0.lowercased().hasSuffix(".safetensors") }.sorted()
        var hits: [URL] = []
        for name in sorted {
            let url = dir.appendingPathComponent(name)
            if weightsFileIsValid(url) { hits.append(url.standardizedFileURL) }
        }
        return hits.count == 1 ? hits[0] : hits.first
    }

    /// Resolve path for job execution; HF download uses venv `hf` when needed.
    static func resolvePath(
        presetID: String,
        catalog: [String: LoRAEntry],
        config: AppConfig
    ) async throws -> String {
        let id = normalizePresetID(presetID)
        if id == "none" { throw LoRAPathError.invalidPreset }
        guard let entry = catalog[id] else { throw LoRAPathError.unknownPreset(id) }
        if let local = localWeightsPath(loraID: id, entry: entry) {
            return local.path
        }
        guard !entry.repoID.isEmpty, !entry.filename.isEmpty else {
            throw LoRAPathError.missingWeights(id)
        }
        let python = await MainActor.run { config.imagegenVenvPythonPath() }
        return try await downloadFromHub(entry: entry, pythonExecutable: python)
    }

    @MainActor
    static func downloadFromHub(entry: LoRAEntry, config: AppConfig) async throws -> String {
        guard !entry.repoID.isEmpty, !entry.filename.isEmpty else {
            throw LoRAPathError.missingWeights(entry.loraID)
        }
        let python = config.imagegenVenvPythonPath()
        return try await downloadFromHub(entry: entry, pythonExecutable: python)
    }

    private static func downloadFromHub(entry: LoRAEntry, pythonExecutable: String) async throws -> String {
        guard let dest = catalogCachePath(entry: entry) else {
            throw LoRAPathError.missingWeights(entry.loraID)
        }
        let destDir = dest.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        if weightsFileIsValid(dest) { return dest.path }

        let python = pythonExecutable
        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw LoRAPathError.pythonRequired
        }
        return try await Task.detached(priority: .userInitiated) { () async throws -> String in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: python)
            proc.arguments = [
                "-c",
                """
                from huggingface_hub import hf_hub_download
                import sys
                p = hf_hub_download(repo_id=sys.argv[1], filename=sys.argv[2], local_dir=sys.argv[3])
                print(p)
                """,
                entry.repoID,
                entry.filename,
                destDir.path,
            ]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            try proc.run()
            proc.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard proc.terminationStatus == 0, !out.isEmpty else {
                throw LoRAPathError.downloadFailed
            }
            return out
        }.value
    }

    static func normalizePresetID(_ raw: Any?) -> String {
        if let s = raw as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "none" : t
        }
        return "none"
    }
}

enum LoRAPathError: LocalizedError {
    case invalidPreset
    case unknownPreset(String)
    case missingWeights(String)
    case pythonRequired
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .invalidPreset: return "Invalid LoRA preset."
        case .unknownPreset(let id): return "Unknown LoRA preset: \(id)."
        case .missingWeights(let id): return "LoRA weights not found: \(id)."
        case .pythonRequired: return "Image generation Python environment is required to download LoRA weights."
        case .downloadFailed: return "LoRA download failed."
        }
    }
}
