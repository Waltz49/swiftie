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
        }
        return true
    }

    static func missingModelIDs(profile: ProfilePaths, ids: [String]) -> [String] {
        ids.filter { id in
            guard let entry = ModelManifest.entry(id: id) else { return true }
            return !isModelInstalled(profile: profile, entry: entry)
        }
    }
}
