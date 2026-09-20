import CryptoKit
import Foundation

extension Notification.Name {
    static let faceModelsInstalled = Notification.Name("FaceModelsInstalled")
}

/// Consent-gated download of dlib `.dat` models into the profile.
@MainActor
enum FaceModelDownloadService {
    static func ensureModelsInstalled(
        profile: ProfilePaths,
        config: AppConfig,
        purpose: String,
        allowDownloadPrompt: Bool = true
    ) async throws {
        guard !FaceModelManifest.isInstalled(profile: profile) else {
            FaceEngine.loadModelsIfNeeded(profile: profile)
            return
        }

        if !allowDownloadPrompt {
            throw ModelDownloadError.modelsNotInstalled
        }

        let downloadBase = config.imageRecognitionModelDownloadBaseURL()
        guard FaceModelManifest.resolveZipURL(profile: profile, downloadBaseURL: downloadBase) != nil
            || FaceModelManifest.mirrorZipURL(profile: profile) != nil else {
            let installPath = profile.dlibModelsDirectory.path
            let mirror = ImageRecognitionPaths.modelsRoot(profile: profile)
                .appendingPathComponent("_mirror", isDirectory: true).path
            throw ModelDownloadError.downloadNotConfigured(
                installPath: installPath,
                mirrorPath: mirror,
                modelNames: FaceModelManifest.catalog.downloadFile
            )
        }

        let cat = FaceModelManifest.catalog
        let sizeText = ByteCountFormatter.string(fromByteCount: cat.approximateDownloadBytes, countStyle: .file)
        let installPath = profile.dlibModelsDirectory.path
        let message = """
        \(purpose)

        The following will be downloaded (~\(sizeText) total):
        • \(cat.displayName)

        Files are stored at:
        \(installPath)

        To remove them later: Settings → Caches → Clear Face, or delete the folder above.
        """

        let choice = StyledMessageDialog.present(
            title: "Download Face Models",
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

        let panel = CancellableProgressPanelController(
            title: "Download Face Models",
            labelText: "Preparing…",
            maximum: 1000
        )
        panel.onCancel = { ActiveModelDownload.shared.cancelInFlight() }
        panel.show()

        do {
            try await downloadAndInstall(
                profile: profile,
                downloadBase: downloadBase,
                reportLabel: { panel.update(label: $0) },
                isCancelled: { panel.cancelRequested }
            )
            panel.close()
            FaceEngine.loadModelsIfNeeded(profile: profile)
            NotificationCenter.default.post(name: .faceModelsInstalled, object: nil)
        } catch {
            panel.close()
            throw error
        }
    }

    private static func downloadAndInstall(
        profile: ProfilePaths,
        downloadBase: String,
        reportLabel: @escaping (String) -> Void,
        isCancelled: @escaping () -> Bool
    ) async throws {
        guard let zipURL = FaceModelManifest.mirrorZipURL(profile: profile)
            ?? FaceModelManifest.resolveZipURL(profile: profile, downloadBaseURL: downloadBase) else {
            throw ModelDownloadError.invalidURL
        }

        let fm = FileManager.default
        let destDir = profile.dlibModelsDirectory
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        let zipOnDisk: URL
        let shouldDelete: Bool
        if zipURL.isFileURL {
            zipOnDisk = zipURL
            shouldDelete = false
        } else {
            reportLabel("Downloading…")
            let (temp, response) = try await ImageRecognitionModelDownloadSession.download(from: zipURL) { _, _ in }
            if isCancelled() {
                try? fm.removeItem(at: temp)
                throw ModelDownloadError.userDeclined
            }
            if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
                try? fm.removeItem(at: temp)
                throw ModelDownloadError.downloadFailed("HTTP \(http.statusCode)")
            }
            zipOnDisk = temp
            shouldDelete = true
        }
        defer { if shouldDelete { try? fm.removeItem(at: zipOnDisk) } }

        reportLabel("Unpacking…")
        let extractRoot = destDir.appendingPathComponent("_unpack", isDirectory: true)
        try? fm.removeItem(at: extractRoot)
        try fm.createDirectory(at: extractRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: extractRoot) }
        try unzipArchive(at: zipOnDisk, to: extractRoot)

        for artifact in FaceModelManifest.catalog.artifacts {
            guard let found = findFile(named: artifact.fileName, under: extractRoot) else {
                throw ModelDownloadError.unzipFailed
            }
            let target = destDir.appendingPathComponent(artifact.fileName)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: found, to: target)
        }
    }

    private static func unzipArchive(at zipURL: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-xk", zipURL.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ModelDownloadError.unzipFailed }
    }

    private static func findFile(named name: String, under root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let url as URL in enumerator where url.lastPathComponent == name {
            return url
        }
        return nil
    }
}
