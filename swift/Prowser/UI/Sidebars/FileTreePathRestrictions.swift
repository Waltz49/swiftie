import Foundation

/// Port of `utils.is_root_or_system_volume` and tree rename permission checks.
enum FileTreePathRestrictions {
    static func isRootOrSystemVolume(_ directoryPath: String) -> Bool {
        let path = URL(fileURLWithPath: directoryPath).standardizedFileURL.path
        if path == "/" { return true }
        if path == "/System" || path.hasPrefix("/System/") { return true }
        if path == "/System/Volumes" || path.hasPrefix("/System/Volumes/") { return true }

        if path.hasPrefix("/Volumes/") {
            let rootDevice = deviceID(for: "/")
            let volumeDevice = deviceID(for: path)
            if let rootDevice, let volumeDevice, rootDevice == volumeDevice {
                return true
            }
        }
        return false
    }

    static func canRenameDirectory(_ directoryPath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: directoryPath) else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryPath, isDirectory: &isDir), isDir.boolValue else {
            return false
        }

        let parent = (directoryPath as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parent) else { return false }

        var statInfo = stat()
        guard stat(directoryPath, &statInfo) == 0 else { return false }
        return (statInfo.st_mode & 0o200) != 0
    }

    static func restrictedActionMessage(for directoryPath: String) -> String {
        if directoryPath == "/" {
            return "This action is not available on the root directory."
        }
        return "This action is not available on system volumes."
    }

    private static func deviceID(for path: String) -> dev_t? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return info.st_dev
    }
}
