import Foundation

/// Download catalog for dlib `.dat` face models (not bundled in the app).
enum FaceModelManifest {
    struct Artifact: Codable, Sendable {
        let fileName: String
        let sha256: String
        let byteSize: Int64
    }

    struct Catalog: Codable, Sendable {
        let version: Int
        let bundleId: String
        let displayName: String
        let downloadFile: String
        let approximateDownloadBytes: Int64
        let artifacts: [Artifact]
    }

    static let bundleID = "dlib_face_models"

    static var catalog: Catalog {
        if let loaded = loadBundled() { return loaded }
        return Catalog(
            version: 1,
            bundleId: bundleID,
            displayName: "dlib face recognition models",
            downloadFile: "dlib_face_models.zip",
            approximateDownloadBytes: 31_000_000,
            artifacts: [
                Artifact(fileName: "shape_predictor_5_face_landmarks.dat", sha256: "", byteSize: 9_969_393),
                Artifact(fileName: "dlib_face_recognition_resnet_model_v1.dat", sha256: "", byteSize: 21_440_102),
            ]
        )
    }

    private static func loadBundled() -> Catalog? {
        guard let url = Bundle.main.url(forResource: "dlib_face_models", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Catalog.self, from: data)
    }

    static func isInstalled(profile: ProfilePaths) -> Bool {
        missingArtifactNames(profile: profile).isEmpty
    }

    static func missingArtifactNames(profile: ProfilePaths) -> [String] {
        let dir = profile.dlibModelsDirectory
        return catalog.artifacts.compactMap { artifact -> String? in
            let path = dir.appendingPathComponent(artifact.fileName)
            return FileManager.default.fileExists(atPath: path.path) ? nil : artifact.fileName
        }
    }

    static func resolveZipURL(profile: ProfilePaths, downloadBaseURL: String) -> URL? {
        let cat = catalog
        if let mirror = mirrorZipURL(profile: profile) { return mirror }
        let base = downloadBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        if base.hasPrefix("file://") {
            return URL(string: base)?.appendingPathComponent(cat.downloadFile)
        }
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URL(string: "\(trimmed)/\(cat.downloadFile)")
    }

    static func mirrorZipURL(profile: ProfilePaths) -> URL? {
        let mirror = ImageRecognitionPaths.modelsRoot(profile: profile)
            .appendingPathComponent("_mirror", isDirectory: true)
            .appendingPathComponent(catalog.downloadFile)
        return FileManager.default.fileExists(atPath: mirror.path) ? mirror : nil
    }
}
