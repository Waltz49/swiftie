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

    static func validateMoveDestinationPath(_ path: String) -> SettingsPathValidationState {
        directoryValidationState(path)
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
