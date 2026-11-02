import AppKit
import Foundation

/// Port of ``chat_prompt_config`` favorite image storage under ``chat_favorite_images/``.
@MainActor
enum ChatUserPromptFavoriteImages {
    private static let directoryName = "chat_favorite_images"

    static func favoriteImagesDirectory(dataDirectory: URL) -> URL {
        let url = dataDirectory.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func existingImagePaths(_ paths: [String]?) -> [String] {
        guard let paths else { return [] }
        return paths.filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }
    }

    static func isValidImageFile(at path: String, imageExtensions: [String]) -> Bool {
        guard FileManager.default.isReadableFile(atPath: path) else { return false }
        let ext = (path as NSString).pathExtension.lowercased()
        let normalized = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
        let allowed = Set(imageExtensions.map {
            AppConfig.normalizeExtension($0).lowercased().replacingOccurrences(of: ".", with: "")
        })
        guard allowed.contains(normalized) else { return false }
        return NSImage(contentsOfFile: path) != nil
    }

    static func isManagedFavoriteImage(path: String, dataDirectory: URL) -> Bool {
        let root = favoriteImagesDirectory(dataDirectory: dataDirectory).standardizedFileURL.path
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.path
        return resolved.hasPrefix(root + "/") || resolved == root
    }

    static func persistFavoriteImagePaths(
        favoriteID: String,
        sourcePaths: [String],
        dataDirectory: URL,
        imageExtensions: [String],
        maxImages: Int = 4
    ) -> [String] {
        let limit = min(maxImages, ChatImageStore.maxChatImages)
        let destDir = favoriteImagesDirectory(dataDirectory: dataDirectory)
        let favRoot = destDir.standardizedFileURL.path
        var stored: [String] = []

        for (idx, src) in sourcePaths.prefix(limit).enumerated() {
            guard !src.isEmpty else { continue }
            let absSrc = URL(fileURLWithPath: src).standardizedFileURL.path
            if absSrc.hasPrefix(favRoot + "/"), isValidImageFile(at: absSrc, imageExtensions: imageExtensions) {
                stored.append(absSrc)
                continue
            }
            guard isValidImageFile(at: absSrc, imageExtensions: imageExtensions) else { continue }
            let ext = (absSrc as NSString).pathExtension
            let suffix = ext.isEmpty ? "png" : ext.lowercased()
            let dest = destDir.appendingPathComponent("\(favoriteID)_\(idx).\(suffix)")
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: URL(fileURLWithPath: absSrc), to: dest)
                stored.append(dest.standardizedFileURL.path)
            } catch {
                continue
            }
        }
        return stored
    }

    static func removeFavoriteImageFiles(paths: [String], dataDirectory: URL) {
        for path in paths {
            guard !path.isEmpty, isManagedFavoriteImage(path: path, dataDirectory: dataDirectory) else { continue }
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}

enum ChatUserPromptAppendLogic {
    /// Port of ``_append_favorite_prompt_text``.
    static func append(existing: String, addition: String) -> String {
        let trimmedAddition = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedAddition.isEmpty { return existing }
        if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return trimmedAddition }
        if let last = existing.last, last.isWhitespace {
            return existing + trimmedAddition
        }
        return existing + " " + trimmedAddition
    }
}

enum ChatUserPromptLibraryTooltip {
    static func radioTooltip(_ text: String, maxChars: Int = 200) -> String {
        let plain = text
        if plain.count <= maxChars { return plain }
        return String(plain.prefix(maxChars)) + "…"
    }
}
