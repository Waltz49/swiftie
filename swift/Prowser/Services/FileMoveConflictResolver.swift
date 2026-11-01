import AppKit
import Foundation

/// Port of `files/file_move_handler.py` — overwrite / rename resolution for move & copy.
@MainActor
enum FileMoveConflictResolver {
    enum ConflictChoice: Equatable {
        case skip
        case replace
        case rename
        case cancelAll
    }

    struct ApplyToAllState {
        var action: ConflictChoice?
        var applyToAll = false
    }

    /// Standardized destination path for a source basename (matches transfer loop expectations).
    static func normalizedTargetPath(sourcePath: String, targetDirectory: String) -> String {
        let dir = URL(fileURLWithPath: (targetDirectory as NSString).expandingTildeInPath).standardizedFileURL
        let name = (sourcePath as NSString).lastPathComponent
        return dir.appendingPathComponent(name).standardizedFileURL.path
    }

    private static func isExistingFile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return false }
        return !isDir.boolValue
    }

    /// Path of an existing file at the destination that should trigger the overwrite dialog.
    static func existingConflictTarget(sourcePath: String, targetDirectory: String) -> String? {
        let primary = normalizedTargetPath(sourcePath: sourcePath, targetDirectory: targetDirectory)
        if isExistingFile(primary) {
            return primary
        }

        let dirURL = URL(fileURLWithPath: (targetDirectory as NSString).expandingTildeInPath).standardizedFileURL
        let sourceName = (sourcePath as NSString).lastPathComponent
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            if entry.lastPathComponent.caseInsensitiveCompare(sourceName) == .orderedSame {
                return entry.standardizedFileURL.path
            }
        }
        return nil
    }

    /// `generate_renamed_path` — `basename-{NNNNN}.ext` using `rename_increment_length`.
    static func generateRenamedPath(
        targetDirectory: String,
        originalFilename: String,
        config: AppConfig
    ) -> String? {
        let nsName = originalFilename as NSString
        let name = nsName.deletingPathExtension
        let ext = nsName.pathExtension
        var incrementLength = config.int(forKey: "rename_increment_length", default: 5)
        incrementLength = max(3, min(6, incrementLength))
        let maxNumber = Int(pow(10.0, Double(incrementLength))) - 1
        let dir = (targetDirectory as NSString).expandingTildeInPath as NSString

        for i in 1 ... maxNumber {
            let formatted = String(format: "%0*d", incrementLength, i)
            let newFilename = ext.isEmpty ? "\(name)-\(formatted)" : "\(name)-\(formatted).\(ext)"
            let newPath = dir.appendingPathComponent(newFilename)
            if !FileManager.default.fileExists(atPath: newPath) {
                return URL(fileURLWithPath: newPath).standardizedFileURL.path
            }
        }
        return nil
    }

    /// Port of `resolve_target_path`.
    static func resolveTargetPath(
        sourcePath: String,
        targetDirectory: String,
        applyToAllState: inout ApplyToAllState,
        config: AppConfig,
        parentWindow: NSWindow? = nil
    ) -> (resolvedPath: String?, cancelAll: Bool) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourcePath, isDirectory: &isDir), !isDir.boolValue else {
            return (nil, false)
        }

        let sourceFilename = (sourcePath as NSString).lastPathComponent
        let defaultTarget = normalizedTargetPath(sourcePath: sourcePath, targetDirectory: targetDirectory)

        guard let existingTarget = existingConflictTarget(sourcePath: sourcePath, targetDirectory: targetDirectory) else {
            return (defaultTarget, false)
        }

        if applyToAllState.applyToAll, let saved = applyToAllState.action {
            switch saved {
            case .skip:
                return (nil, false)
            case .replace:
                return (existingTarget, false)
            case .rename:
                let renamed = generateRenamedPath(
                    targetDirectory: targetDirectory,
                    originalFilename: sourceFilename,
                    config: config
                )
                return (renamed, false)
            case .cancelAll:
                return (nil, true)
            }
        }

        let dialogResult = FileAlreadyExistsDialogController.present(
            sourcePath: sourcePath,
            targetPath: existingTarget,
            parentWindow: parentWindow
        )

        if dialogResult.applyToAll {
            applyToAllState.action = dialogResult.choice
            applyToAllState.applyToAll = true
        }

        switch dialogResult.choice {
        case .cancelAll:
            return (nil, true)
        case .skip:
            return (nil, false)
        case .replace:
            return (existingTarget, false)
        case .rename:
            let renamed = generateRenamedPath(
                targetDirectory: targetDirectory,
                originalFilename: sourceFilename,
                config: config
            )
            return (renamed, false)
        }
    }
}
