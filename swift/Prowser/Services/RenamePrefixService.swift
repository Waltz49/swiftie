import AppKit
import Foundation

/// Rename files with a custom prefix template. Port of `rename_with_custom_prefix` (minimal).
@MainActor
final class RenamePrefixService {
    private weak var appState: AppState?

    func bind(_ appState: AppState) {
        self.appState = appState
    }

    func presentRenameDialog(paths: [String]? = nil) {
        guard let appState else { return }
        guard let directory = appState.fileData.currentDirectory else {
            appState.status.show("No directory is currently open")
            return
        }

        let targetPaths = resolvePaths(paths: paths, directory: directory, appState: appState)
        guard !targetPaths.isEmpty else {
            appState.status.show("No images to rename")
            return
        }

        let settings = appState.config.rawSettings()
        let savedPrefix = settings["rename_custom_prefix"] as? String
            ?? settings["rename_prefix_template"] as? String
            ?? "image-%d"
        let incrementLength = appState.config.int(forKey: "rename_increment_length", default: 5)
        let startingNumber = appState.config.int(forKey: "rename_starting_number", default: 1)

        let alert = NSAlert()
        alert.messageText = "Rename with Custom Prefix"
        alert.informativeText = "Rename \(targetPaths.count) image(s) in \((directory as NSString).lastPathComponent). Use %d for directory name."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = savedPrefix.isEmpty ? "image-%d" : savedPrefix
        alert.accessoryView = field

        guard alert.runModal() == .OK else { return }

        let prefixTemplate = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefixTemplate.isEmpty else {
            appState.status.show("Prefix cannot be empty")
            return
        }

        appState.config.updateSetting("rename_custom_prefix", value: prefixTemplate)

        do {
            let renamed = try rename(
                paths: targetPaths,
                directory: directory,
                prefixTemplate: prefixTemplate,
                incrementLength: incrementLength,
                startingNumber: startingNumber
            )
            if renamed.isEmpty {
                appState.status.show("No files were renamed")
            } else {
                appState.refreshDirectory()
                appState.status.show("Renamed \(renamed.count) file(s)")
            }
        } catch {
            showAlert("Rename Failed", informative: error.localizedDescription)
        }
    }

    private func resolvePaths(paths: [String]?, directory: String, appState: AppState) -> [String] {
        if let paths, !paths.isEmpty {
            return paths.filter {
                ($0 as NSString).deletingLastPathComponent == directory
                    && FileManager.default.fileExists(atPath: $0)
            }
        }
        let selected = appState.selection.selectedFiles.filter {
            ($0 as NSString).deletingLastPathComponent == directory
        }
        if !selected.isEmpty {
            return selected.sorted()
        }
        return appState.fileData.displayedImages.filter {
            ($0 as NSString).deletingLastPathComponent == directory
                && FileManager.default.fileExists(atPath: $0)
        }
    }

    private func rename(
        paths: [String],
        directory: String,
        prefixTemplate: String,
        incrementLength: Int,
        startingNumber: Int
    ) throws -> [String] {
        let dirname = (directory as NSString).lastPathComponent
        let prefix = prefixTemplate
            .replacingOccurrences(of: "%d", with: dirname)
            .replacingOccurrences(of: "%D", with: dirname)
        guard isValidFilenamePrefix(prefix) else {
            throw RenameError.invalidPrefix
        }

        let digits = max(3, min(6, incrementLength))
        let maxSequence = Int(pow(10.0, Double(digits))) - 1
        guard startingNumber <= maxSequence else {
            throw RenameError.startingNumberTooLarge(maxSequence)
        }

        var renamed: [String] = []
        var number = startingNumber
        let fm = FileManager.default

        for path in paths {
            if PrsortIO.isFileLocked(path) { continue }
            let ext = (path as NSString).pathExtension
            let newName = String(format: "%@-%0\(digits)d.%@", prefix, number, ext)
            let newPath = (directory as NSString).appendingPathComponent(newName)
            if fm.fileExists(atPath: newPath) && newPath != path {
                throw RenameError.nameConflict(newName)
            }
            try fm.moveItem(atPath: path, toPath: newPath)
            renamed.append(newPath)
            number += 1
        }
        return renamed
    }

    private func isValidFilenamePrefix(_ prefix: String) -> Bool {
        guard !prefix.isEmpty else { return false }
        let invalid = CharacterSet(charactersIn: "/:\\*?\"<>|")
        return prefix.rangeOfCharacter(from: invalid) == nil
    }

    private func showAlert(_ title: String, informative: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = informative
        alert.runModal()
    }
}

enum RenameError: LocalizedError {
    case invalidPrefix
    case startingNumberTooLarge(Int)
    case nameConflict(String)

    var errorDescription: String? {
        switch self {
        case .invalidPrefix:
            return "Invalid prefix. Avoid / \\ : * ? \" < > | characters."
        case .startingNumberTooLarge(let max):
            return "Starting number exceeds maximum \(max) for the digit width."
        case .nameConflict(let name):
            return "A file named \"\(name)\" already exists."
        }
    }
}
