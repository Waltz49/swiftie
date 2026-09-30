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
        let dir = targetDirectory as NSString

        for i in 1 ... maxNumber {
            let formatted = String(format: "%0*d", incrementLength, i)
            let newFilename = ext.isEmpty ? "\(name)-\(formatted)" : "\(name)-\(formatted).\(ext)"
            let newPath = dir.appendingPathComponent(newFilename)
            if !FileManager.default.fileExists(atPath: newPath) {
                return newPath
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
        let targetPath = (targetDirectory as NSString).appendingPathComponent(sourceFilename)

        guard FileManager.default.fileExists(atPath: targetPath) else {
            return (targetPath, false)
        }

        if applyToAllState.applyToAll, let saved = applyToAllState.action {
            switch saved {
            case .skip:
                return (nil, false)
            case .replace:
                return (targetPath, false)
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
            targetPath: targetPath,
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
            return (targetPath, false)
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
