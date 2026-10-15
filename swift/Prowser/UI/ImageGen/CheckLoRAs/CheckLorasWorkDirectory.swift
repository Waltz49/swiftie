import Foundation

@MainActor
enum CheckLorasWorkDirectory {
    static func directoryPath(config: AppConfig) -> String {
        config.temporaryFilesDirectory.path
    }

    static func containsWorkImages(config: AppConfig) -> Bool {
        let directory = directoryPath(config: config)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        let allowed = Set(
            config.imageExtensions.map {
                let lower = $0.lowercased()
                return lower.hasPrefix(".") ? String(lower.dropFirst()) : lower
            }
        )
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return false
        }
        for name in names where !name.hasPrefix(".") {
            let path = (directory as NSString).appendingPathComponent(name)
            var entryIsDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &entryIsDir), !entryIsDir.boolValue else {
                continue
            }
            let ext = (name as NSString).pathExtension.lowercased()
            if allowed.contains(ext) {
                return true
            }
        }
        return false
    }
}
