import Foundation

enum LoRAInstallError: LocalizedError {
    case notFound(String)
    case noRecoverySource
    case pythonRequired
    case downloadFailed
    case invalidSource

    var errorDescription: String? {
        switch self {
        case .notFound(let id):
            return "LoRA \(id) was not found in the catalog."
        case .noRecoverySource:
            return "No download link or Hugging Face repo is configured for this LoRA."
        case .pythonRequired:
            return "Image Generation Python environment is required to download from Hugging Face."
        case .downloadFailed:
            return "LoRA download failed."
        case .invalidSource:
            return "The configured download source is not valid."
        }
    }
}

/// Install LoRA weights from HF or a remote `.safetensors` URL (Settings → LoRA Install).
@MainActor
enum LoRAInstallService {
    /// True when Install can fetch weights (HF, direct download URL, or local `.safetensors`).
    static func canDownloadWeights(
        repoID: String,
        filename: String,
        sourcePath: String?,
        safetensorsOrigin: String?,
        localPath: String?
    ) -> Bool {
        let repo = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
        let file = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        if !repo.isEmpty, !file.isEmpty { return true }
        if directHTTPDownloadURL(sourcePath: sourcePath, safetensorsOrigin: safetensorsOrigin) != nil {
            return true
        }
        for raw in [sourcePath, localPath] {
            let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let lower = text.lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") { continue }
            let url = URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
            if LoRAPathResolver.weightsFileIsValid(url) { return true }
        }
        return false
    }

    /// HTTP URL shown as the install download target (HF resolve, direct download, or stored origin).
    static func primaryHTTPDownloadURLString(
        repoID: String,
        filename: String,
        sourcePath: String?,
        safetensorsOrigin: String?
    ) -> String? {
        let repo = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
        let file = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        if !repo.isEmpty, !file.isEmpty {
            return "https://huggingface.co/\(repo)/resolve/main/\(file)"
        }
        if let direct = directHTTPDownloadURL(sourcePath: sourcePath, safetensorsOrigin: safetensorsOrigin) {
            return direct
        }
        for raw in [safetensorsOrigin, sourcePath] {
            let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://") else { continue }
            if LoRAURLValidation.normalizedHTTPURL(text) != nil { return text }
        }
        return nil
    }

    static func httpURLPathEndsWithSafetensors(_ urlString: String) -> Bool {
        if let url = URL(string: urlString) {
            return url.path.lowercased().hasSuffix(".safetensors")
        }
        return urlString.lowercased().hasSuffix(".safetensors")
    }

    /// When Install should open the model page instead of download confirmation or progress.
    static func webPageToOpenInsteadOfInstall(
        repoID: String,
        filename: String,
        sourcePath: String?,
        safetensorsOrigin: String?,
        webPageURL: String,
        canDownload: Bool
    ) -> URL? {
        let page = webPageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized = LoRAURLValidation.normalizedHTTPURL(page),
              let url = URL(string: normalized)
        else { return nil }
        if !canDownload { return url }
        guard let fileURL = primaryHTTPDownloadURLString(
            repoID: repoID,
            filename: filename,
            sourcePath: sourcePath,
            safetensorsOrigin: safetensorsOrigin
        ) else { return nil }
        if httpURLPathEndsWithSafetensors(fileURL) { return nil }
        return url
    }

    /// First HTTP URL that looks like a direct weights download (not a model page).
    static func directHTTPDownloadURL(sourcePath: String?, safetensorsOrigin: String?) -> String? {
        for raw in [safetensorsOrigin, sourcePath] {
            let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://") else { continue }
            guard LoRAURLClassification.isDownloadLikeURL(text) else { continue }
            if LoRAURLValidation.normalizedHTTPURL(text) != nil { return text }
        }
        return nil
    }

    static func installSourceDescription(
        repoID: String,
        filename: String,
        sourcePath: String,
        safetensorsOrigin: String
    ) -> String {
        let repo = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
        let file = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        if !repo.isEmpty, !file.isEmpty {
            return "https://huggingface.co/\(repo)/resolve/main/\(file)"
        }
        if let origin = directHTTPDownloadURL(
            sourcePath: sourcePath.isEmpty ? nil : sourcePath,
            safetensorsOrigin: safetensorsOrigin.isEmpty ? nil : safetensorsOrigin
        ) {
            return origin
        }
        let source = sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !source.isEmpty, LoRAURLClassification.isDownloadLikeURL(source) { return source }
        let origin = safetensorsOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
        if !origin.isEmpty, LoRAURLClassification.isDownloadLikeURL(origin) { return origin }
        return "configured download source"
    }

    static func install(loraID: String, store: LoRACatalogStore, config: AppConfig) async throws {
        let lc = store.load()
        guard let entry = LoRACatalog.getEntry(loraID: loraID, lc: lc) else {
            throw LoRAInstallError.notFound(loraID)
        }
        if LoRAPathResolver.localWeightsPath(loraID: loraID, entry: entry) != nil {
            if let path = entry.localPath, !path.isEmpty { return }
            if let path = LoRAPathResolver.localWeightsPath(loraID: loraID, entry: entry)?.path {
                persistLocalPath(loraID: loraID, path: path, store: store)
            }
            return
        }
        guard LoRAEntry.hasRecoverySource(
            repoID: entry.repoID,
            filename: entry.filename,
            sourcePath: entry.sourcePath,
            safetensorsOrigin: entry.safetensorsOrigin,
            webPageURL: entry.webPageURL,
            localPath: entry.localPath
        ) else {
            throw LoRAInstallError.noRecoverySource
        }

        let installedPath: String
        if !entry.repoID.isEmpty, !entry.filename.isEmpty {
            installedPath = try await LoRAPathResolver.downloadFromHub(entry: entry, config: config)
        } else if let url = remoteDownloadURL(entry: entry) {
            let dest = try await downloadFromHTTP(url: url, entry: entry)
            installedPath = dest.path
        } else if let source = localSourceFile(entry: entry) {
            let dest = try LoRAUserEntries.copyToUserCache(source: source, loraID: entry.loraID)
            installedPath = dest.path
        } else {
            throw LoRAInstallError.noRecoverySource
        }

        persistLocalPath(loraID: loraID, path: installedPath, store: store)
    }

    private static func remoteDownloadURL(entry: LoRAEntry) -> URL? {
        guard let text = directHTTPDownloadURL(sourcePath: entry.sourcePath, safetensorsOrigin: entry.safetensorsOrigin),
              let url = URL(string: text)
        else { return nil }
        return url
    }

    private static func localSourceFile(entry: LoRAEntry) -> URL? {
        for raw in [entry.sourcePath, entry.localPath] {
            let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://") { continue }
            let url = URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
            if LoRAPathResolver.weightsFileIsValid(url) { return url.standardizedFileURL }
        }
        return nil
    }

    private static func downloadFromHTTP(url: URL, entry: LoRAEntry) async throws -> URL {
        let destDir = LoRACachePaths.userCacheRoot.appendingPathComponent(entry.loraID, isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let name: String = {
            let file = entry.filename.trimmingCharacters(in: .whitespacesAndNewlines)
            if !file.isEmpty { return file }
            let last = url.lastPathComponent
            if last.lowercased().hasSuffix(".safetensors") { return last }
            return "\(entry.loraID).safetensors"
        }()
        let dest = destDir.appendingPathComponent(name)

        let tmp: URL = try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: url) { location, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let location,
                      let http = response as? HTTPURLResponse,
                      (200 ... 299).contains(http.statusCode) else {
                    continuation.resume(throwing: LoRAInstallError.downloadFailed)
                    return
                }
                continuation.resume(returning: location)
            }
            task.resume()
        }

        defer { try? FileManager.default.removeItem(at: tmp) }
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: tmp, to: dest)
        guard LoRAPathResolver.weightsFileIsValid(dest) else {
            try? FileManager.default.removeItem(at: dest)
            throw LoRAInstallError.downloadFailed
        }
        return dest.standardizedFileURL
    }

    private static func persistLocalPath(loraID: String, path: String, store: LoRACatalogStore) {
        var lc = store.load()
        guard var users = lc[LoRACatalogSettings.userEntriesKey] as? [String: Any] else { return }
        var dict = (users[loraID] as? [String: Any]) ?? [:]
        if dict.isEmpty { return }
        dict["local_path"] = path
        users[loraID] = dict
        lc[LoRACatalogSettings.userEntriesKey] = users
        store.save(lc)
    }
}