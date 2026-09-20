import Foundation

/// Foreground face scan marker (port of `faces/face_gathering_coordinator.py`).
enum FaceGatheringCoordinator {
    static func setForegroundFaceScanActive(_ active: Bool, profile: ProfilePaths) {
        let path = profile.foregroundFaceScanActiveMarker
        if active {
            try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path.path, contents: Data())
        } else {
            try? FileManager.default.removeItem(at: path)
        }
    }

    static func isForegroundFaceScanActive(profile: ProfilePaths) -> Bool {
        FileManager.default.fileExists(atPath: profile.foregroundFaceScanActiveMarker.path)
    }
}
