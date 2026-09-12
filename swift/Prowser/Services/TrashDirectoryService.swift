import Foundation

/// macOS Trash directory discovery and image collection. Port of `FileOperationsManager._get_all_readable_trash_directories` / `browse_trash_images`.
enum TrashDirectoryService {
    static func readableTrashDirectories() -> [String] {
        var trashDirs: [String] = []
        let userTrash = (NSHomeDirectory() as NSString).appendingPathComponent(".Trash")
        if isReadableDirectory(userTrash) {
            trashDirs.append(userTrash)
        }

        let uid = getuid()
        let volumes = "/Volumes"
        guard let volumeNames = try? FileManager.default.contentsOfDirectory(atPath: volumes) else {
            return trashDirs
        }
        for volumeName in volumeNames where !volumeName.hasPrefix(".") {
            let volumePath = (volumes as NSString).appendingPathComponent(volumeName)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: volumePath, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let userTrashPath = (volumePath as NSString)
                .appendingPathComponent(".Trashes/\(uid)")
            if isReadableDirectory(userTrashPath) {
                trashDirs.append(userTrashPath)
            }
        }
        return trashDirs
    }

    static func hasReadableTrashWithImages(extensions: [String]) -> Bool {
        let extSet = normalizedExtensions(extensions)
        for trashDir in readableTrashDirectories() {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: trashDir) else { continue }
            for file in files {
                let path = (trashDir as NSString).appendingPathComponent(file)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
                      !isDir.boolValue,
                      extSet.contains((file as NSString).pathExtension.lowercased()) else { continue }
                return true
            }
        }
        return false
    }

    static func collectTrashImagePaths(extensions: [String]) -> [String] {
        let extSet = normalizedExtensions(extensions)
        var results: [String] = []
        for trashDir in readableTrashDirectories() {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: trashDir) else { continue }
            for file in files {
                let path = (trashDir as NSString).appendingPathComponent(file)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
                      !isDir.boolValue,
                      extSet.contains((file as NSString).pathExtension.lowercased()) else { continue }
                results.append(path)
            }
        }
        return results.sorted()
    }

    private static func isReadableDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        guard FileManager.default.isReadableFile(atPath: path) else { return false }
        return (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
    }

    private static func normalizedExtensions(_ extensions: [String]) -> Set<String> {
        Set(
            extensions.map { ext in
                let trimmed = ext.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return trimmed.hasPrefix(".") ? String(trimmed.dropFirst()) : trimmed
            }
            .filter { !$0.isEmpty }
        )
    }
}
