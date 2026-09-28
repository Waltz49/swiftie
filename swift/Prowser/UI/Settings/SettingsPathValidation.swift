import AppKit
import SwiftUI

extension Notification.Name {
    /// Preferences OK / dismiss: commit path fields that still have keyboard focus (mouse OK does not blur SwiftUI fields).
    static let prowserCommitSettingsPathFields = Notification.Name("prowser.commitSettingsPathFields")
}

/// Visual state for path fields (Python settings dialog validation QLabel).
enum SettingsPathValidationState: Equatable {
    case empty
    case valid(tooltip: String)
    case invalid(tooltip: String)
}

@MainActor
enum SettingsPathValidation {
    static func expandedPath(_ path: String) -> String {
        (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    }

    /// Settings UI display form (`~/…` under the user home directory). Python `_path_to_display`.
    static func displayPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return StatusBarFormatter.displayPath(expandedPath(trimmed))
    }

    /// After editing, normalize visible text to display form while keeping storage expanded on persist.
    static func normalizedDisplayPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return displayPath(trimmed)
    }

    /// Display form for typed paths: on-disk component casing for existing prefixes, then `~/…` shortening.
    static func normalizedTypedPathDisplayPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let cased = pathWithFilesystemNameCasing(trimmed)
        return displayPath(cased)
    }

    /// Expanded path with filesystem casing (settings storage).
    static func normalizedStoredPath(_ path: String) -> String {
        expandedPath(normalizedTypedPathDisplayPath(path))
    }

    static func normalizedExitScriptCommandDisplay(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let parsed = ExitScriptUtils.parseExitScriptCommand(trimmed)
        guard !parsed.path.isEmpty else { return trimmed }
        let pathForDisplay = displayPath(pathWithFilesystemNameCasing(parsed.path))
        return ExitScriptUtils.formatExitScriptCommand(prefix: parsed.prefix, path: pathForDisplay)
    }

    static func normalizedStoredExitScriptCommand(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let parsed = ExitScriptUtils.parseExitScriptCommand(trimmed)
        guard !parsed.path.isEmpty else { return trimmed }
        let expandedScriptPath = normalizedStoredPath(parsed.path)
        return ExitScriptUtils.formatExitScriptCommand(prefix: parsed.prefix, path: expandedScriptPath)
    }

    static func normalizedOptionalPathSlotsForStorage(_ values: [String?]) -> [String?] {
        values.map { value in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return normalizedStoredPath(trimmed)
        }
    }

    static func normalizedPathDictionaryEntriesForStorage(_ entries: [[String: Any]]) -> [[String: Any]] {
        entries.map { entry in
            guard let path = entry["path"] as? String else { return entry }
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return entry }
            var updated = entry
            updated["path"] = normalizedStoredPath(trimmed)
            return updated
        }
    }

    static func normalizedRootDirectoriesForStorage(_ paths: [String]) -> [String] {
        paths.map { path in
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return path }
            return pathWithFilesystemNameCasing(trimmed)
        }
    }

    /// Preferences OK: rewrite path-related settings using on-disk name casing.
    static func normalizePathRelatedSettings(config: AppConfig) {
        config.setExcludeDirectories(
            normalizedPathDictionaryEntriesForStorage(config.excludeDirectories())
        )
        config.setIgnoreDirectories(
            normalizedPathDictionaryEntriesForStorage(config.ignoreDirectories())
        )
        config.setOptionalStringArray(
            "favorite_directories",
            values: normalizedOptionalPathSlotsForStorage(config.favoriteDirectories())
        )
        config.setOptionalStringArray(
            "move_destinations",
            values: normalizedOptionalPathSlotsForStorage(config.moveDestinations())
        )
        config.setValue(
            normalizedRootDirectoriesForStorage(config.rootDirectories()),
            forKey: "root_directories"
        )
        if let rawTemp = config.temporaryFilesDirectoryRaw(),
           !rawTemp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            config.setTemporaryFilesDirectory(normalizedStoredPath(rawTemp))
        }
        config.setValue(
            normalizedStoredExitScriptCommand(config.string(forKey: ExitScriptUtils.settingTextAIExit)),
            forKey: ExitScriptUtils.settingTextAIExit
        )
        config.setValue(
            normalizedStoredExitScriptCommand(config.string(forKey: ExitScriptUtils.settingImageAIExit)),
            forKey: ExitScriptUtils.settingImageAIExit
        )
    }

    /// Rewrites each resolved path component to the on-disk name (APFS/HFS+ case-insensitive, case-preserving).
    /// Non-absolute substrings (folder-name fragments) are returned unchanged aside from trimming.
    static func pathWithFilesystemNameCasing(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return path }
        let expanded = expandedPath(trimmed)
        let hadTrailingSlash = expanded.hasSuffix("/") && expanded != "/"
        guard expanded.hasPrefix("/") else { return trimmed }

        let fm = FileManager.default
        var resolved = ""
        var currentDirectory = URL(fileURLWithPath: "/", isDirectory: true)
        let components = expanded.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return expanded }

        for (index, component) in components.enumerated() {
            guard let names = try? fm.contentsOfDirectory(atPath: currentDirectory.path) else {
                if resolved.isEmpty { return expanded }
                resolved += "/" + components[index...].joined(separator: "/")
                break
            }
            guard let actualName = names.first(where: {
                $0.compare(component, options: .caseInsensitive) == .orderedSame
            }) else {
                if resolved.isEmpty { return expanded }
                resolved += "/" + components[index...].joined(separator: "/")
                break
            }
            resolved += "/" + actualName
            let nextPath = currentDirectory.appendingPathComponent(actualName).path
            currentDirectory = URL(fileURLWithPath: nextPath, isDirectory: true)
        }

        if resolved.isEmpty { return expanded }
        if hadTrailingSlash, !resolved.hasSuffix("/") {
            resolved += "/"
        }
        return resolved
    }

    /// End field editing and notify `SettingsPathTextField` instances to run blur normalization.
    static func commitPendingPathFieldEdits() {
        if let window = NSApp.keyWindow {
            window.endEditing(for: nil)
            window.makeFirstResponder(nil)
        }
        NotificationCenter.default.post(name: .prowserCommitSettingsPathFields, object: nil)
    }

    static func validateMoveDestinationPath(_ path: String) -> SettingsPathValidationState {
        validateDirectoryPath(path)
    }

    static func validateFavoriteDestinationPath(
        _ path: String,
        imageExtensions: [String]
    ) -> SettingsPathValidationState {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }

        let fullPath = expandedPath(trimmed)
        let fm = FileManager.default
        var isDirectory: ObjCBool = false

        if fm.fileExists(atPath: fullPath, isDirectory: &isDirectory), isDirectory.boolValue {
            return .valid(tooltip: "Valid directory:\n\(fullPath)")
        }

        var isFile: ObjCBool = false
        if fm.fileExists(atPath: fullPath, isDirectory: &isFile), !isFile.boolValue {
            if isImageFile(fullPath, imageExtensions: imageExtensions) {
                return .valid(tooltip: "Valid image file:\n\(fullPath)")
            }
            let ext = (fullPath as NSString).pathExtension
            let extLabel = ext.isEmpty ? "none" : ".\(ext.lowercased())"
            return .invalid(tooltip: "File is not an image file\n(extension: \(extLabel))")
        }

        if fm.fileExists(atPath: fullPath) {
            return .invalid(
                tooltip: "Path exists but is not a directory or image file:\n\(fullPath)"
            )
        }
        return .invalid(tooltip: "Path does not exist: \(fullPath)")
    }

    static func validateDirectoryPath(_ path: String) -> SettingsPathValidationState {
        directoryValidationState(path)
    }

    private static func directoryValidationState(_ path: String) -> SettingsPathValidationState {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }

        let fullPath = expandedPath(trimmed)
        var isDirectory: ObjCBool = false
        let fm = FileManager.default

        if fm.fileExists(atPath: fullPath, isDirectory: &isDirectory), isDirectory.boolValue {
            return .valid(tooltip: "Valid directory:\n\(fullPath)")
        }

        if fm.fileExists(atPath: fullPath) {
            return .invalid(tooltip: "Path exists but is not a directory:\n\(fullPath)")
        }
        return .invalid(tooltip: "Path does not exist: \(fullPath)")
    }

    private static func isImageFile(_ path: String, imageExtensions: [String]) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let allowed = Set(imageExtensions.map { normalizeExtension($0) })
        return allowed.contains(ext)
    }

    private static func normalizeExtension(_ ext: String) -> String {
        let lower = ext.lowercased()
        if lower.hasPrefix(".") { return String(lower.dropFirst()) }
        return lower
    }
}

struct SettingsPathValidationIndicator: View {
    let state: SettingsPathValidationState

    var body: some View {
        Group {
            switch state {
            case .empty:
                Color.clear
            case .valid(let tooltip):
                Text("✓")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.green)
                    .help(tooltip)
            case .invalid(let tooltip):
                Text("✗")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.red)
                    .help(tooltip)
            }
        }
        .frame(width: 20)
    }
}

/// Path/filename field: shortens to `~/…` on blur and Return (Python `_path_to_display` on field exit).
@MainActor
struct SettingsPathTextField: View {
    let title: String
    @Binding var text: String
    var prompt: Text?
    var help: String?
    /// Exit-script row (`python /path/to/script.py`): normalize the script path token only.
    var exitScriptCommand = false
    var onCommit: (() -> Void)? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if let prompt {
                TextField(title, text: $text, prompt: prompt)
            } else {
                TextField(title, text: $text)
            }
        }
        .textFieldStyle(.roundedBorder)
        .focused($isFocused)
        .onChange(of: isFocused) { wasFocused, nowFocused in
            if wasFocused, !nowFocused {
                shortenOnBlur()
            }
        }
        .onSubmit { shortenOnBlur() }
        .onReceive(NotificationCenter.default.publisher(for: .prowserCommitSettingsPathFields)) { _ in
            shortenOnBlur()
        }
        .help(help ?? title)
    }

    private func shortenOnBlur() {
        let normalized = if exitScriptCommand {
            SettingsPathValidation.normalizedExitScriptCommandDisplay(text)
        } else {
            SettingsPathValidation.normalizedTypedPathDisplayPath(text)
        }
        if normalized != text {
            text = normalized
        }
        onCommit?()
    }
}
