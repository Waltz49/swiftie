import Foundation

enum FaceRecognitionCapabilities {
    static func facesUIEnabled(launchOptions: LaunchOptions) -> Bool {
        !launchOptions.minBundle
    }

    static func faceFeaturesAvailable(profile: ProfilePaths) -> Bool {
        FaceEngine.isBridgeLinked() && FaceModelManifest.isInstalled(profile: profile)
    }
}
