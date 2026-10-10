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

    static func weightsFileIsValid(_ path: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue >= 1024 else { return false }
        if path.pathExtension.lowercased() != "safetensors" { return true }
        guard let handle = try? FileHandle(forReadingFrom: path) else { return false }
        defer { try? handle.close() }
        let prefix = handle.readData(ofLength: 8)
        return prefix.count >= 8
    }

    static func localWeightsPath(loraID: String, entry: LoRAEntry?) -> URL? {
        guard let entry else { return nil }
        if let local = entry.localPath, !local.isEmpty {
            let url = URL(fileURLWithPath: (local as NSString).expandingTildeInPath)
            if weightsFileIsValid(url) { return url.standardizedFileURL }
        }
        if let cache = catalogCachePath(entry: entry), weightsFileIsValid(cache) {
            return cache.standardizedFileURL
        }
        let alt = LoRACachePaths.altCache
            .appendingPathComponent(entry.repoID.replacingOccurrences(of: "/", with: "__"), isDirectory: true)
            .appendingPathComponent(entry.filename)
        if weightsFileIsValid(alt) { return alt.standardizedFileURL }
        return nil
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
