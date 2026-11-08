import Foundation

/// Resolves expand/infill source paths (Python ``_ensure_panel`` + pending ``source_path``).
enum ImageGenSingleSourceBootstrap {
    struct Input: Equatable {
        var forceFromActive: Bool
        var lockedPath: String?
        var valuePath: String?
        var restoredLastDialogPath: String?
        var activePath: String?
    }

    struct Output: Equatable {
        var path: String?
    }

    static func resolve(_ input: Input) -> Output {
        if input.forceFromActive, let path = normalizedExistingFile(input.activePath) {
            return Output(path: path)
        }
        if let path = normalizedExistingFile(input.lockedPath) {
            return Output(path: path)
        }
        if let path = normalizedExistingFile(input.valuePath) {
            return Output(path: path)
        }
        if let path = normalizedExistingFile(input.restoredLastDialogPath) {
            return Output(path: path)
        }
        if let path = normalizedExistingFile(input.activePath) {
            return Output(path: path)
        }
        return Output(path: nil)
    }

    private static func normalizedExistingFile(_ path: String?) -> String? {
        let trimmed = (path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = (trimmed as NSString).standardizingPath
        guard FileManager.default.fileExists(atPath: normalized) else { return nil }
        return normalized
    }
}

extension ImageGenDialogRequest {
    /// Plain open for last-used function (⌥/) without job edit, EXIF fast-open, or explicit overrides.
    var isPlainLastSettingsOpen: Bool {
        replaceJobID == nil
            && openWithLastSettings
            && !primeSourceFromActiveImage
            && !autoImportEXIF
            && !autoGenerate
            && editSourcePaths.isEmpty
            && initialPrompt == nil
    }
}
