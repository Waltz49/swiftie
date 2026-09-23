import Foundation
import ProwserDlibBridge

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
        if FaceModelManifest.isInstalled(profile: profile) {
            try verifyRuntimeReady(profile: profile)
            return
        }

        if !allowDownloadPrompt {
            throw ModelDownloadError.modelsNotInstalled
        }

        let downloadBase = config.imageRecognitionModelDownloadBaseURL()
        guard FaceModelManifest.isDownloadAvailable(profile: profile, downloadBaseURL: downloadBase) else {
            throw faceModelsNotConfiguredError(profile: profile, downloadBase: downloadBase)
        }

        let cat = FaceModelManifest.catalog
        let sizeText = ByteCountFormatter.string(fromByteCount: cat.approximateDownloadBytes, countStyle: .file)
        let installPath = profile.dlibModelsDirectory.path
        let zipSource = FaceModelManifest.mirrorZipURL(profile: profile)?.path
            ?? FaceModelManifest.remoteZipURL(downloadBaseURL: downloadBase)?.absoluteString
            ?? cat.downloadFile
        let message = """
        \(purpose)

        The following will be downloaded (~\(sizeText) total):
        • \(cat.displayName) (\(cat.downloadFile))

        Source:
        \(zipSource)

        Files are stored at:
        \(installPath)
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

        let progressScale = 1000
        let panel = CancellableProgressPanelController(
            title: "Download Face Models",
            labelText: "Preparing…",
            maximum: progressScale
        )
        panel.onCancel = { ActiveModelDownload.shared.cancelInFlight() }
        panel.show()

        ActiveModelDownload.shared.begin()
        defer {
            ActiveModelDownload.shared.end()
            panel.close()
        }

        let isCancelled: @Sendable () -> Bool = { panel.cancelRequested }
        let reportLabel: @Sendable (String) -> Void = { text in
            panel.update(label: text)
        }
        let reportProgress: @Sendable (Int64, Int64) -> Void = { written, expected in
            let fraction: Double
            if expected > 0 {
                fraction = min(1, Double(written) / Double(expected))
            } else {
                fraction = written > 0 ? 0.05 : 0
            }
            let writtenText = ByteCountFormatter.string(fromByteCount: written, countStyle: .file)
            let label: String
            if expected > 0 {
                let expectedText = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
                let percent = Int((fraction * 100).rounded())
                label = "Downloading \(cat.downloadFile)… \(writtenText) of \(expectedText) (\(percent)%)"
            } else {
                label = "Downloading \(cat.downloadFile)… \(writtenText)"
            }
            panel.update(value: Int(fraction * Double(progressScale)), label: label)
        }

        var installAttempted = false
        do {
            try await Task.detached(priority: .userInitiated) {
                do {
                    try await FaceModelInstallBackend.downloadAndInstall(
                        profile: profile,
                        downloadBase: downloadBase,
                        isCancelled: isCancelled,
                        reportLabel: reportLabel,
                        reportDownloadProgress: reportProgress
                    )
                } catch let error as URLError {
                    throw Self.mapURLError(error, downloadBase: downloadBase, profile: profile)
                }
            }.value
            installAttempted = true
            try verifyRuntimeReady(profile: profile)
            NotificationCenter.default.post(name: .faceModelsInstalled, object: nil)
        } catch ModelDownloadError.userDeclined {
            if installAttempted || !FaceModelManifest.isInstalled(profile: profile) {
                FaceModelInstallBackend.removeInstalledArtifacts(profile: profile)
            }
            throw ModelDownloadError.userDeclined
        } catch {
            if installAttempted || !FaceModelManifest.isInstalled(profile: profile) {
                FaceModelInstallBackend.removeInstalledArtifacts(profile: profile)
            }
            throw error
        }
    }

    /// Throws if dlib is unavailable or `.dat` files cannot be loaded.
    static func verifyRuntimeReady(profile: ProfilePaths) throws {
        guard FaceEngine.isBridgeLinked() else {
            throw ModelDownloadError.downloadFailed(
                "Native dlib is not linked in this build. Run swift/Scripts/build_dlib_macos.sh and rebuild (do not use --skip-dlib)."
            )
        }
        guard FaceModelManifest.isInstalled(profile: profile) else {
            throw ModelDownloadError.modelsNotInstalled
        }
        guard FaceEngine.loadModelsIfNeeded(profile: profile) else {
            let dir = profile.dlibModelsDirectory.path
            let zipName = FaceModelManifest.catalog.downloadFile
            throw ModelDownloadError.downloadFailed(
                """
                Face model files are present but could not be loaded.

                Remove the files under:
                \(dir)

                Then download again, or place a valid \(zipName) in:
                \(ImageRecognitionPaths.modelsRoot(profile: profile).appendingPathComponent("_mirror", isDirectory: true).path)
                """
            )
        }
    }

    private static func faceModelsNotConfiguredError(profile: ProfilePaths, downloadBase: String) -> ModelDownloadError {
        let cat = FaceModelManifest.catalog
        let installPath = profile.dlibModelsDirectory.path
        let mirror = ImageRecognitionPaths.modelsRoot(profile: profile)
            .appendingPathComponent("_mirror", isDirectory: true).path
        let expectedURL = FaceModelManifest.remoteZipURL(downloadBaseURL: downloadBase)?.absoluteString
            ?? "(configure Settings → Models for Search)"
        return .downloadFailed(
            """
            Face models are not installed and no download source is available.

            Expected archive: \(cat.downloadFile)
            Expected download URL: \(expectedURL)

            Offline mirror (place zip here):
            \(mirror)/\(cat.downloadFile)

            Or install these files directly under:
            \(installPath)
            • \(cat.artifacts.map(\.fileName).joined(separator: "\n• "))

            Default download folder: \(ImageRecognitionDownloadDefaults.defaultBaseURL)
            See swift/Scripts/DLIB_FACE_MODELS.md.
            """
        )
    }

    nonisolated private static func mapURLError(
        _ error: URLError,
        downloadBase: String,
        profile: ProfilePaths
    ) -> ModelDownloadError {
        let mirror = ImageRecognitionPaths.modelsRoot(profile: profile)
            .appendingPathComponent("_mirror", isDirectory: true).path
        let hint = "Copy \(FaceModelManifest.catalog.downloadFile) into \(mirror) or fix the URL under Settings → Models for Search."
        switch error.code {
        case .secureConnectionFailed, .serverCertificateUntrusted, .clientCertificateRejected, .clientCertificateRequired:
            return .downloadFailed(
                "Secure connection failed (\(error.localizedDescription)). \(hint)"
            )
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost:
            return .downloadFailed(
                "Could not download \(FaceModelManifest.catalog.downloadFile) (\(error.localizedDescription)). \(hint)"
            )
        default:
            return .downloadFailed(error.localizedDescription)
        }
    }

    /// Delete installed dlib `.dat` files and unload from memory (debug / reinstall testing).
    static func removeInstalledModels(profile: ProfilePaths) throws -> Int {
        ProwserDlibBridge.unloadModels()
        return FaceModelInstallBackend.removeInstalledArtifacts(profile: profile)
    }
}

/// Heavy download / unzip off the main thread so the progress panel stays responsive.
private enum FaceModelInstallBackend {
    static func downloadAndInstall(
        profile: ProfilePaths,
        downloadBase: String,
        isCancelled: @escaping @Sendable () -> Bool,
        reportLabel: @escaping @Sendable (String) -> Void,
        reportDownloadProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        guard let zipURL = FaceModelManifest.mirrorZipURL(profile: profile)
            ?? FaceModelManifest.remoteZipURL(downloadBaseURL: downloadBase) else {
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
            guard fm.fileExists(atPath: zipOnDisk.path) else {
                throw ModelDownloadError.downloadFailed("Local model archive not found: \(zipOnDisk.path)")
            }
        } else {
            if isCancelled() { throw ModelDownloadError.userDeclined }
            reportLabel("Connecting…")
            let (temp, response) = try await ImageRecognitionModelDownloadSession.download(
                from: zipURL,
                onProgress: reportDownloadProgress
            )
            if isCancelled() {
                try? fm.removeItem(at: temp)
                throw ModelDownloadError.userDeclined
            }
            if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
                try? fm.removeItem(at: temp)
                throw ModelDownloadError.downloadFailed(
                    "HTTP \(http.statusCode) for \(zipURL.absoluteString). The server may not host \(FaceModelManifest.catalog.downloadFile) yet."
                )
            }
            zipOnDisk = temp
            shouldDelete = true
        }
        defer { if shouldDelete { try? fm.removeItem(at: zipOnDisk) } }

        if isCancelled() { throw ModelDownloadError.userDeclined }
        reportLabel("Unpacking…")
        let extractRoot = destDir.appendingPathComponent("_unpack", isDirectory: true)
        try? fm.removeItem(at: extractRoot)
        try fm.createDirectory(at: extractRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: extractRoot) }
        try unzipArchive(at: zipOnDisk, to: extractRoot)

        for artifact in FaceModelManifest.catalog.artifacts {
            if isCancelled() { throw ModelDownloadError.userDeclined }
            guard let found = findFile(named: artifact.fileName, under: extractRoot) else {
                throw ModelDownloadError.downloadFailed(
                    "Archive did not contain \(artifact.fileName). Expected a zip named \(FaceModelManifest.catalog.downloadFile) with the dlib face model files."
                )
            }
            let target = destDir.appendingPathComponent(artifact.fileName)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: found, to: target)
        }

        guard FaceModelManifest.isInstalled(profile: profile) else {
            throw ModelDownloadError.unzipFailed
        }
    }

    @discardableResult
    static func removeInstalledArtifacts(profile: ProfilePaths) -> Int {
        let fm = FileManager.default
        let dir = profile.dlibModelsDirectory
        var removed = 0
        for artifact in FaceModelManifest.catalog.artifacts {
            let path = dir.appendingPathComponent(artifact.fileName)
            if fm.fileExists(atPath: path.path) {
                try? fm.removeItem(at: path)
                removed += 1
            }
        }
        try? fm.removeItem(at: dir.appendingPathComponent("_unpack", isDirectory: true))
        return removed
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
