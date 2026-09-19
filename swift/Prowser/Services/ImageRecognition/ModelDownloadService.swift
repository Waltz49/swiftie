import CryptoKit
import Foundation

enum ModelDownloadError: Error, LocalizedError, Sendable {
    case userDeclined
    case invalidURL
    case downloadFailed(String)
    case checksumMismatch
    case unzipFailed
    case missingManifestEntry
    case downloadNotConfigured(installPath: String, mirrorPath: String, modelNames: String)

    var errorDescription: String? {
        switch self {
        case .userDeclined: return "Download was not approved."
        case .invalidURL: return "Invalid model download URL."
        case .downloadFailed(let msg): return msg
        case .checksumMismatch: return "Downloaded model failed verification."
        case .unzipFailed: return "Could not unpack model archive."
        case .missingManifestEntry: return "Unknown model."
        case .downloadNotConfigured(let installPath, let mirrorPath, let modelNames):
            return """
            Search models are not installed.

            Install Core ML packages manually under:
            \(installPath)

            Or place zip archives here (same names as in the manifest):
            \(mirrorPath)

            Expected: \(modelNames)

            Default download folder: \(ImageRecognitionDownloadDefaults.defaultBaseURL)

            Change or reset the URL under Settings → Models for Search. See swift/Scripts/IMAGE_RECOGNITION_MODELS.md.
            """
        }
    }
}

/// Consent-gated download and install of Core ML model packages into the profile.
@MainActor
enum ModelDownloadService {
    static func ensureModelsInstalled(
        profile: ProfilePaths,
        config: AppConfig,
        modelIDs: [String],
        purpose: String
    ) async throws {
        let downloadBase = config.imageRecognitionModelDownloadBaseURL()
        await ModelManifest.refreshRemoteCatalog(profile: profile, downloadBaseURL: downloadBase)
        ModelManifest.loadUserCatalog(profile: profile)

        let missing = ImageRecognitionPaths.missingModelIDs(profile: profile, ids: modelIDs)
        guard !missing.isEmpty else { return }

        let entries = missing.compactMap { ModelManifest.entry(id: $0) }
        guard entries.count == missing.count else { throw ModelDownloadError.missingManifestEntry }

        if !ModelManifest.isDownloadAvailable(
            profile: profile,
            downloadBaseURL: downloadBase,
            modelIDs: missing
        ) {
            let names = entries.map { $0.artifacts.first?.fileName ?? $0.displayName }.joined(separator: ", ")
            let mirror = ImageRecognitionPaths.modelsRoot(profile: profile)
                .appendingPathComponent("_mirror", isDirectory: true).path
            throw ModelDownloadError.downloadNotConfigured(
                installPath: ImageRecognitionPaths.modelsRoot(profile: profile).path,
                mirrorPath: mirror,
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

        let progressScale = 1000
        let panel = CancellableProgressPanelController(
            title: "Download Search Models",
            labelText: "Preparing…",
            maximum: progressScale
        )
        panel.onCancel = { ActiveModelDownload.shared.cancelInFlight() }
        panel.show()

        let isCancelled: @Sendable () -> Bool = { panel.cancelRequested }
        let entryCount = entries.count
        let byteFormatter: ByteCountFormatter = {
            let f = ByteCountFormatter()
            f.countStyle = .file
            return f
        }()
        let downloadProgressThrottle = DownloadProgressThrottle()
        let reportLabel: @Sendable (String) -> Void = { text in
            panel.update(label: text)
        }

        ActiveModelDownload.shared.begin()
        defer {
            ActiveModelDownload.shared.end()
            panel.close()
        }

        for (index, entry) in entries.enumerated() {
            try ActiveModelDownload.shared.throwIfCancelled()
            let baseProgress = Double(index) / Double(entryCount)
            panel.update(
                value: Int(baseProgress * Double(progressScale)),
                label: "Installing \(entry.displayName)… (\(index + 1)/\(entryCount))"
            )

            let reportDownloadProgress: @Sendable (Int64, Int64) -> Void = { written, expected in
                if !downloadProgressThrottle.shouldEmit(written: written, expected: expected) {
                    return
                }
                let entryFraction: Double
                if expected > 0 {
                    entryFraction = min(1, Double(written) / Double(expected))
                } else {
                    entryFraction = 0
                }
                let overall = (Double(index) + entryFraction) / Double(entryCount)
                let writtenText = byteFormatter.string(fromByteCount: written)
                let label: String
                if expected > 0 {
                    let expectedText = byteFormatter.string(fromByteCount: expected)
                    let percent = Int((entryFraction * 100).rounded())
                    label = "Downloading \(entry.displayName)… \(writtenText) of \(expectedText) (\(percent)%)"
                } else {
                    label = "Downloading \(entry.displayName)… \(writtenText)"
                }
                panel.update(value: Int(overall * Double(progressScale)), label: label)
            }

            try await Task.detached(priority: .userInitiated) {
                do {
                    try await ModelInstallBackend.downloadAndInstall(
                        profile: profile,
                        downloadBase: downloadBase,
                        entry: entry,
                        isCancelled: isCancelled,
                        reportLabel: reportLabel,
                        reportDownloadProgress: reportDownloadProgress
                    )
                } catch let error as URLError {
                    throw Self.mapURLError(error)
                }
            }.value
            try ActiveModelDownload.shared.throwIfCancelled()
            let doneProgress = Double(index + 1) / Double(entryCount)
            panel.update(value: Int(doneProgress * Double(progressScale)), label: entry.displayName)
        }
    }

    nonisolated private static func mapURLError(_ error: URLError) -> ModelDownloadError {
        switch error.code {
        case .secureConnectionFailed, .serverCertificateUntrusted, .clientCertificateRejected, .clientCertificateRequired:
            let mirror = "Copy zip files into your profile’s models/_mirror/ folder (see Settings → Models for Search)."
            return .downloadFailed(
                "Secure connection failed (\(error.localizedDescription)). \(mirror)"
            )
        default:
            return .downloadFailed(error.localizedDescription)
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

private final class DownloadProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEmitUptime: UInt64 = 0

    func shouldEmit(written: Int64, expected: Int64) -> Bool {
        if written == 0 { return true }
        lock.lock()
        defer { lock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        if expected > 0, written < expected, now - lastEmitUptime < 80_000_000 {
            return false
        }
        lastEmitUptime = now
        return true
    }
}

/// Tracks the in-flight `URLSessionDownloadTask` so Cancel can abort HTTPS downloads.
final class ActiveModelDownload: @unchecked Sendable {
    static let shared = ActiveModelDownload()
    private let lock = NSLock()
    private var downloadTask: URLSessionDownloadTask?
    private var userCancelled = false

    func begin() {
        lock.lock()
        userCancelled = false
        downloadTask = nil
        lock.unlock()
    }

    func end() {
        lock.lock()
        downloadTask = nil
        lock.unlock()
    }

    func cancelInFlight() {
        lock.lock()
        userCancelled = true
        downloadTask?.cancel()
        lock.unlock()
    }

    func throwIfCancelled() throws {
        lock.lock()
        let cancelled = userCancelled
        lock.unlock()
        if cancelled { throw ModelDownloadError.userDeclined }
    }

    func registerDownloadTask(_ task: URLSessionDownloadTask) {
        lock.lock()
        downloadTask = task
        if userCancelled {
            task.cancel()
        }
        lock.unlock()
    }

    func clearDownloadTask() {
        lock.lock()
        downloadTask = nil
        lock.unlock()
    }
}

/// Heavy install steps off the main thread so the download panel stays responsive.
private enum ModelInstallBackend {
    static func downloadAndInstall(
        profile: ProfilePaths,
        downloadBase: String,
        entry: ModelManifest.ModelEntry,
        isCancelled: @escaping @Sendable () -> Bool,
        reportLabel: @escaping @Sendable (String) -> Void,
        reportDownloadProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        if isCancelled() { throw ModelDownloadError.userDeclined }

        guard let source = ModelManifest.resolveZipSource(
            profile: profile,
            downloadBaseURL: downloadBase,
            entry: entry
        ) else {
            throw ModelDownloadError.invalidURL
        }

        let fm = FileManager.default
        let destDir = ImageRecognitionPaths.modelInstallDirectory(profile: profile, modelID: entry.id)
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        let zipOnDisk: URL
        let shouldDeleteZip: Bool
        switch source {
        case .localFile(let url):
            zipOnDisk = url
            shouldDeleteZip = false
        case .https(let url):
            if isCancelled() { throw ModelDownloadError.userDeclined }
            let (tempZip, response) = try await ImageRecognitionModelDownloadSession.download(
                from: url,
                onProgress: reportDownloadProgress
            )
            if isCancelled() {
                try? fm.removeItem(at: tempZip)
                throw ModelDownloadError.userDeclined
            }
            if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
                try? fm.removeItem(at: tempZip)
                throw ModelDownloadError.downloadFailed("HTTP \(http.statusCode) for \(url.absoluteString)")
            }
            zipOnDisk = tempZip
            shouldDeleteZip = true
        }
        defer {
            if shouldDeleteZip { try? fm.removeItem(at: zipOnDisk) }
        }

        if let artifact = entry.artifacts.first, !artifact.sha256.isEmpty {
            reportLabel("Verifying \(entry.displayName)…")
            if isCancelled() { throw ModelDownloadError.userDeclined }
            let zipData = try Data(contentsOf: zipOnDisk)
            let digest = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
            if digest.lowercased() != artifact.sha256.lowercased() {
                throw ModelDownloadError.checksumMismatch
            }
        }

        if isCancelled() { throw ModelDownloadError.userDeclined }
        reportLabel("Unpacking \(entry.displayName)…")

        let extractRoot = destDir.appendingPathComponent("_unpack", isDirectory: true)
        try? fm.removeItem(at: extractRoot)
        try fm.createDirectory(at: extractRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: extractRoot) }

        try unzipArchive(at: zipOnDisk, to: extractRoot)
        if isCancelled() { throw ModelDownloadError.userDeclined }

        try installArtifacts(from: extractRoot, entry: entry, destDir: destDir)
        if isCancelled() { throw ModelDownloadError.userDeclined }

        reportLabel("Compiling \(entry.displayName)…")
        if isCancelled() { throw ModelDownloadError.userDeclined }
        let packageNames = entry.artifacts.map(\.fileName)
        try compilePackages(packageNames: packageNames, in: destDir, isCancelled: isCancelled)
    }

    private static func compilePackages(
        packageNames: [String],
        in destDir: URL,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws {
        let fm = FileManager.default
        for name in packageNames where name.hasSuffix(".mlpackage") {
            if isCancelled() { throw ModelDownloadError.userDeclined }
            let package = destDir.appendingPathComponent(name)
            guard fm.fileExists(atPath: package.path) else { continue }
            _ = try CoreMLModelCompilation.ensureCompiled(at: package)
        }
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
            if artifact.fileName.hasSuffix(".mlpackage") {
                let staleCompiled = CoreMLModelCompilation.compiledSiblingURL(for: target)
                if fm.fileExists(atPath: staleCompiled.path) {
                    try fm.removeItem(at: staleCompiled)
                }
            }
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
}
