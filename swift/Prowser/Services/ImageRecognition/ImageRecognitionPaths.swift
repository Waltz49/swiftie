import Foundation

enum ImageRecognitionPaths {
    static func modelsRoot(profile: ProfilePaths) -> URL {
        profile.imageRecognitionCacheDirectory
            .appendingPathComponent("models", isDirectory: true)
    }

    static func modelInstallDirectory(profile: ProfilePaths, modelID: String) -> URL {
        modelsRoot(profile: profile).appendingPathComponent(modelID, isDirectory: true)
    }

    static func artifactURL(profile: ProfilePaths, modelID: String, fileName: String) -> URL {
        modelInstallDirectory(profile: profile, modelID: modelID).appendingPathComponent(fileName, isDirectory: false)
    }

    static func isModelInstalled(profile: ProfilePaths, entry: ModelManifest.ModelEntry) -> Bool {
        let dir = modelInstallDirectory(profile: profile, modelID: entry.id)
        for artifact in entry.artifacts {
            let path = dir.appendingPathComponent(artifact.fileName)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir) else {
                return false
            }
            if artifact.fileName.hasSuffix(".mlpackage"), !isValidMLPackage(at: path) {
                return false
            }
        }
        return true
    }

    /// Core ML requires `Manifest.json` at the package root; partial copies often omit it.
    static func isValidMLPackage(at packageURL: URL) -> Bool {
        let manifest = packageURL.appendingPathComponent("Manifest.json")
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: manifest.path, isDirectory: &isDir) && !isDir.boolValue
    }

    static func missingModelIDs(profile: ProfilePaths, ids: [String]) -> [String] {
        ids.filter { id in
            guard let entry = ModelManifest.entry(id: id) else { return true }
            return !isModelInstalled(profile: profile, entry: entry)
        }
    }

    /// True when CLIP and ResNet Core ML bundles for current settings are on disk (background UI gate).
    @MainActor
    static func backgroundIndexingAvailable(profile: ProfilePaths, config: AppConfig) -> Bool {
        let resnet = config.string(forKey: "resnet_model", default: "resnet18")
        let clip = config.string(forKey: "clip_model_name", default: "openai/clip-vit-base-patch32")
        let resnetIDs = ModelManifest.resnetBundleIDs(for: resnet)
        let clipIDs = ModelManifest.clipBundleIDs(for: clip)
        return missingModelIDs(profile: profile, ids: resnetIDs).isEmpty
            && missingModelIDs(profile: profile, ids: clipIDs).isEmpty
    }
}
