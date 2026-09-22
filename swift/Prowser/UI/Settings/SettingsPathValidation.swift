import SwiftUI

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
        .help(help ?? title)
    }

    private func shortenOnBlur() {
        let normalized = SettingsPathValidation.normalizedDisplayPath(text)
        if normalized != text {
            text = normalized
        }
        onCommit?()
    }
}
