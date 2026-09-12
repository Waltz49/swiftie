import Foundation

/// Move Work Files workflow. Port of `image_browser_window.move_work_files`.
enum MoveWorkFilesService {
    static func canMoveWorkFiles(currentDirectory: String?) -> Bool {
        resolveWorkDirectory(currentDirectory: currentDirectory) != nil
    }

    static func resolveWorkDirectory(currentDirectory: String?) -> String? {
        guard let currentDir = normalizedDirectory(currentDirectory) else { return nil }
        let parent = (currentDir as NSString).deletingLastPathComponent
        let sibling = (parent as NSString).appendingPathComponent("work")
        if isDirectory(sibling) { return sibling }
        let child = (currentDir as NSString).appendingPathComponent("work")
        if isDirectory(child) { return child }
        return nil
    }

    static func imageFilesInWorkDirectory(
        workDirectory: String,
        extensions: [String]
    ) -> [String] {
        let extSet = Set(
            extensions.map {
                let e = $0.lowercased()
                return e.hasPrefix(".") ? String(e.dropFirst()) : e
            }
        )
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: workDirectory) else {
            return []
        }
        return entries.compactMap { name -> String? in
            guard !name.hasPrefix(".") else { return nil }
            let path = (workDirectory as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
                return nil
            }
            let ext = (name as NSString).pathExtension.lowercased()
            guard extSet.contains(ext) else { return nil }
            return path
        }
    }

    @MainActor
    static func moveWorkFiles(
        appState: AppState,
        destinationName: String
    ) throws -> Int {
        guard let currentDir = normalizedDirectory(appState.fileData.currentDirectory) else {
            throw MoveWorkError.noCurrentDirectory
        }
        guard let workDir = resolveWorkDirectory(currentDirectory: currentDir) else {
            throw MoveWorkError.noWorkDirectory
        }
        let files = imageFilesInWorkDirectory(
            workDirectory: workDir,
            extensions: appState.config.imageExtensions
        )
        guard !files.isEmpty else {
            throw MoveWorkError.noFiles
        }

        let workParent = (workDir as NSString).deletingLastPathComponent
        let destPath = (workParent as NSString).appendingPathComponent(destinationName)
        if FileManager.default.fileExists(atPath: destPath) {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: destPath, isDirectory: &isDir)
            guard isDir.boolValue else { throw MoveWorkError.destinationNotDirectory }
        } else {
            try FileManager.default.createDirectory(
                atPath: destPath,
                withIntermediateDirectories: true
            )
        }

        var moved = 0
        for source in files {
            let dest = (destPath as NSString).appendingPathComponent((source as NSString).lastPathComponent)
            if FileManager.default.fileExists(atPath: dest) {
                continue
            }
            try FileManager.default.moveItem(atPath: source, toPath: dest)
            moved += 1
        }
        if moved > 0 {
            appState.refreshDirectory()
        }
        return moved
    }

    private static func normalizedDirectory(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        var normalized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        while normalized.hasSuffix("/"), normalized.count > 1 {
            normalized.removeLast()
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return normalized
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}

enum MoveWorkError: LocalizedError {
    case noCurrentDirectory
    case noWorkDirectory
    case noFiles
    case destinationNotDirectory
    case invalidName

    var errorDescription: String? {
        switch self {
        case .noCurrentDirectory: return "No current directory found."
        case .noWorkDirectory:
            return "A 'work' directory must exist as either a sibling or child of the current directory."
        case .noFiles: return "No image files to move in the work directory."
        case .destinationNotDirectory: return "Target path exists but is not a directory."
        case .invalidName: return "Invalid directory name."
        }
    }
}
