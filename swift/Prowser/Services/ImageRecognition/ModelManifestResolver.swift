import Foundation

extension ModelManifest {
    enum ZipSource: Sendable {
        case https(URL)
        case localFile(URL)
    }

    private static var userCatalog: Catalog?

    /// Fetches `image_recognition_models.json` from the download base (HTTPS) before installs.
    static func refreshRemoteCatalog(profile: ProfilePaths, downloadBaseURL: String) async {
        let base = downloadBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty,
              let url = URL(string: "\(base.hasSuffix("/") ? String(base.dropLast()) : base)/image_recognition_models.json"),
              url.scheme == "https",
              isValidHTTPSHost(url) else { return }
        do {
            let (data, response) = try await ImageRecognitionModelDownloadSession.session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else { return }
            guard (try? JSONDecoder().decode(Catalog.self, from: data)) != nil else { return }
            let dest = profile.imageRecognitionCacheDirectory
                .appendingPathComponent("image_recognition_models.json")
            try data.write(to: dest, options: .atomic)
            loadUserCatalog(profile: profile)
        } catch {
            loadUserCatalog(profile: profile)
        }
    }

    static func loadUserCatalog(profile: ProfilePaths) {
        let url = profile.imageRecognitionCacheDirectory
            .appendingPathComponent("image_recognition_models.json")
        guard let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else {
            userCatalog = nil
            return
        }
        userCatalog = catalog
    }

    static func activeCatalog() -> Catalog {
        userCatalog ?? bundledCatalog
    }

    static func packageZipFileName(for entry: ModelEntry) -> String {
        if let downloadFile = entry.downloadFile, !downloadFile.isEmpty {
            return downloadFile
        }
        let raw = entry.downloadURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty, let url = URL(string: raw), !url.isFileURL {
            return url.lastPathComponent
        }
        return "\(entry.id).zip"
    }

    static func localMirrorZipURL(profile: ProfilePaths, entry: ModelEntry) -> URL {
        ImageRecognitionPaths.modelsRoot(profile: profile)
            .appendingPathComponent("_mirror", isDirectory: true)
            .appendingPathComponent(packageZipFileName(for: entry), isDirectory: false)
    }

    static func resolveZipSource(
        profile: ProfilePaths,
        downloadBaseURL: String,
        entry: ModelEntry
    ) -> ZipSource? {
        let mirror = localMirrorZipURL(profile: profile, entry: entry)
        if FileManager.default.fileExists(atPath: mirror.path) {
            return .localFile(mirror)
        }

        let raw = entry.downloadURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty, let url = URL(string: raw) {
            if url.isFileURL, FileManager.default.fileExists(atPath: url.path) {
                return .localFile(url)
            }
            if url.scheme == "https", isValidHTTPSHost(url) {
                return .https(url)
            }
        }

        let base = downloadBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }

        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        let fileName = packageZipFileName(for: entry)
        if trimmedBase.hasPrefix("file://"), let fileBase = URL(string: trimmedBase) {
            let zip = fileBase.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: zip.path) {
                return .localFile(zip)
            }
            return nil
        }

        guard let composed = URL(string: "\(trimmedBase)/\(fileName)"),
              composed.scheme == "https",
              isValidHTTPSHost(composed) else {
            return nil
        }
        return .https(composed)
    }

    static func isDownloadAvailable(
        profile: ProfilePaths,
        downloadBaseURL: String,
        modelIDs: [String]
    ) -> Bool {
        loadUserCatalog(profile: profile)
        let entries = modelIDs.compactMap { ModelManifest.entry(id: $0) }
        guard entries.count == modelIDs.count, !entries.isEmpty else { return false }
        return entries.allSatisfy {
            resolveZipSource(profile: profile, downloadBaseURL: downloadBaseURL, entry: $0) != nil
        }
    }

    private static func isValidHTTPSHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "example.invalid" || host.hasSuffix(".invalid") { return false }
        return true
    }
}
