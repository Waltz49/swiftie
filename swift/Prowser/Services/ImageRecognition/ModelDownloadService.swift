import CryptoKit
import Foundation

enum ModelDownloadError: Error, LocalizedError {
    case userDeclined
    case invalidURL
    case downloadFailed(String)
    case checksumMismatch
    case unzipFailed
    case missingManifestEntry
    case downloadNotConfigured(installPath: String, modelNames: String)

    var errorDescription: String? {
        switch self {
        case .userDeclined: return "Download was not approved."
        case .invalidURL: return "Invalid model download URL."
        case .downloadFailed(let msg): return msg
        case .checksumMismatch: return "Downloaded model failed verification."
        case .unzipFailed: return "Could not unpack model archive."
        case .missingManifestEntry: return "Unknown model."
        case .downloadNotConfigured(let installPath, let modelNames):
            return """
            Search models are not installed and automatic download is not configured yet.

            Install Core ML packages manually under:
            \(installPath)

            Expected: \(modelNames)

            See swift/Scripts/IMAGE_RECOGNITION_MODELS.md in the project repo.
            """
        }
    }
}

/// Consent-gated download and install of Core ML model packages into the profile.
@MainActor
enum ModelDownloadService {
    static func ensureModelsInstalled(
        profile: ProfilePaths,
        modelIDs: [String],
        purpose: String
    ) async throws {
        let missing = ImageRecognitionPaths.missingModelIDs(profile: profile, ids: modelIDs)
        guard !missing.isEmpty else { return }

        let entries = missing.compactMap { ModelManifest.entry(id: $0) }
        guard entries.count == missing.count else { throw ModelDownloadError.missingManifestEntry }

        if !ModelManifest.isRemoteDownloadAvailable(modelIDs: missing) {
            let names = entries.map { $0.artifacts.first?.fileName ?? $0.displayName }.joined(separator: ", ")
            throw ModelDownloadError.downloadNotConfigured(
                installPath: ImageRecognitionPaths.modelsRoot(profile: profile).path,
                modelNames: names
            )
        }

        let totalBytes = entries.reduce(Int64(0)) { $0 + $1.approximateDownloadBytes }
        let sizeText = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        let names = entries.map(\.displayName).joined(separator: "\n• ")
        let installPath = ImageRecognitionPaths.modelsRoot(profile: profile).path

        let message = """
        \(purpose)

        The following will be downloaded (~\(sizeText) total):
        • \(names)

        Files are stored at:
        \(installPath)

        To remove them later: Settings → Caches → Clear Image Rec, or delete the models folder above.
        """

        let choice = StyledMessageDialog.present(
            title: "Download Search Models",
            message: message,
            style: .informational,
            icon: .question,
            buttons: [
                StyledMessageDialog.Button("Cancel", role: .dismissive),
                StyledMessageDialog.Button("Download"),
            ],
            defaultButtonIndex: 1,
            escapeButtonIndex: 0
        )
        guard choice == 1 else { throw ModelDownloadError.userDeclined }

        for entry in entries {
            try await downloadAndInstall(profile: profile, entry: entry)
        }
    }

    private static func downloadAndInstall(
        profile: ProfilePaths,
        entry: ModelManifest.ModelEntry
    ) async throws {
        guard let url = URL(string: entry.downloadURL), url.scheme == "https" else {
            throw ModelDownloadError.invalidURL
        }

        let fm = FileManager.default
        let destDir = ImageRecognitionPaths.modelInstallDirectory(profile: profile, modelID: entry.id)
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        let (tempZip, response) = try await URLSession.shared.download(from: url)
        defer { try? fm.removeItem(at: tempZip) }

        if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
            throw ModelDownloadError.downloadFailed("HTTP \(http.statusCode)")
        }

        let zipData = try Data(contentsOf: tempZip)
        if let artifact = entry.artifacts.first, !artifact.sha256.isEmpty {
            let digest = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
            if digest.lowercased() != artifact.sha256.lowercased() {
                throw ModelDownloadError.checksumMismatch
            }
        }

        let extractRoot = destDir.appendingPathComponent("_unpack", isDirectory: true)
        try? fm.removeItem(at: extractRoot)
        try fm.createDirectory(at: extractRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: extractRoot) }

        try unzipArchive(at: tempZip, to: extractRoot)
        try installArtifacts(from: extractRoot, entry: entry, destDir: destDir)
    }

    private static func installArtifacts(
        from extractRoot: URL,
        entry: ModelManifest.ModelEntry,
        destDir: URL
    ) throws {
        let fm = FileManager.default
        for artifact in entry.artifacts {
            guard let found = findFile(named: artifact.fileName, under: extractRoot) else {
                throw ModelDownloadError.unzipFailed
            }
            let target = destDir.appendingPathComponent(artifact.fileName)
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.copyItem(at: found, to: target)
        }
    }

    private static func findFile(named name: String, under root: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator {
            if url.lastPathComponent == name { return url }
        }
        return nil
    }

    private static func unzipArchive(at zipURL: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-xk", zipURL.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ModelDownloadError.unzipFailed
        }
    }

    static func removeAllDownloadedModels(profile: ProfilePaths) throws {
        let root = ImageRecognitionPaths.modelsRoot(profile: profile)
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
}
