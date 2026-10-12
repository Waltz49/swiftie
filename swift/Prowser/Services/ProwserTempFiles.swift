import Foundation

/// Port of `prowser_temp_files.py` (path resolution for settings UI).
enum ProwserTempFiles {
    private static var cachedRaw: String?
    private static var cachedResolved: String?

    static func invalidateCache() {
        cachedRaw = nil
        cachedResolved = nil
    }

    static func defaultTemporaryFilesDirectory(prowserHome: URL) -> String {
        prowserHome.appendingPathComponent("tmp", isDirectory: true).path
    }

    static func resolveTemporaryFilesDirectory(settings: [String: Any], prowserHome: URL) -> String {
        let raw = settings["temporary_files_directory"]
        if let path = raw as? String, !path.trimmingCharacters(in: .whitespaces).isEmpty {
            return (path as NSString).expandingTildeInPath
        }
        return defaultTemporaryFilesDirectory(prowserHome: prowserHome)
    }

    static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    static func makeInfillBatchDirectory(tempRoot: URL) -> String {
        let base = tempRoot.standardizedFileURL.path
        let name = "imagegen-infill-\(UUID().uuidString)"
        let path = (base as NSString).appendingPathComponent(name)
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    static func pixelmatorExportDirectory(tempRoot: URL) -> String {
        let path = tempRoot.appendingPathComponent("pixelmator", isDirectory: true).path
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    static func imageGenProgressDirectory(prowserHome: URL? = nil) -> String {
        let home = prowserHome ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(ProfilePaths.defaultProfileDirectoryName, isDirectory: true)
        let dir = home.appendingPathComponent("tmp/imagegen-progress", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private static let legacyProgressPrefix = ".imagegen-progress-"

    /// Remove ``{profile}/tmp/imagegen-progress`` on shutdown (debug off), matching profile tmp cleanup.
    static func cleanupImageGenProgressDirectoryOnShutdown(prowserHome: URL, debugMode: Bool) {
        guard !debugMode else { return }
        let dir = imageGenProgressDirectory(prowserHome: prowserHome)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return }
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// Port of ``prowser_temp_files.cleanup_stale_imagegen_worker_temps`` (orphaned files in profile tmp).
    static func cleanupStaleImageGenWorkerTemps(prowserHome: URL, debugMode: Bool) {
        guard !debugMode else { return }
        let tmpDir = (imageGenProgressDirectory(prowserHome: prowserHome) as NSString).deletingLastPathComponent
        let prefixes = [
            "imagegen-mflux-",
            "imagegen-progress-",
            "imagegen-expand-base-",
            "imagegen-mflux-infill-",
            "imagegen-mflux-infill-mask-",
            "imagegen-mflux-fill-",
            "imagegen-mflux-mask-",
        ]
        let dirPrefixes = ["imagegen-mflux-stepwise-"]
        let protectedDirPrefixes = ["imagegen-infill-"]
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: tmpDir) else { return }
        for name in names {
            let full = (tmpDir as NSString).appendingPathComponent(name)
            if protectedDirPrefixes.contains(where: { name.hasPrefix($0) }) {
                continue
            }
            if dirPrefixes.contains(where: { name.hasPrefix($0) }) {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                    try? FileManager.default.removeItem(atPath: full)
                }
                continue
            }
            if prefixes.contains(where: { name.hasPrefix($0) }) {
                try? FileManager.default.removeItem(atPath: full)
            }
        }
    }

    /// Remove loose image files directly inside ``{profile}/tmp`` on shutdown.
    /// Other files and subdirectories are preserved.
    @MainActor
    static func cleanupProfileTemporaryImagesOnShutdown(
        prowserHome: URL,
        imageExtensions: [String],
        debugMode: Bool
    ) {
        guard !debugMode else { return }
        let extensions = Set(imageExtensions.map { AppConfig.normalizeExtension($0) })
        guard !extensions.isEmpty else { return }

        let tmpDirectory = prowserHome.appendingPathComponent("tmp", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: tmpDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return
        }
        for entry in entries {
            guard extensions.contains(AppConfig.normalizeExtension(entry.pathExtension)),
                  (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// Port of ``prowser_temp_files.cleanup_cancelled_generation_output_artifacts``.
    static func cleanupCancelledGenerationOutputArtifacts(outputPath: String) {
        guard !outputPath.isEmpty else { return }
        let fm = FileManager.default
        let sidecar = outputPath + ".tmp"
        if fm.fileExists(atPath: sidecar) {
            try? fm.removeItem(atPath: sidecar)
        }
        let directory = URL(fileURLWithPath: outputPath).deletingLastPathComponent().path
        if let names = try? fm.contentsOfDirectory(atPath: directory) {
            for name in names where name.hasPrefix(legacyProgressPrefix) && name.hasSuffix(".png") {
                try? fm.removeItem(atPath: (directory as NSString).appendingPathComponent(name))
            }
        }
        guard fm.fileExists(atPath: outputPath),
              let attrs = try? fm.attributesOfItem(atPath: outputPath),
              let size = attrs[.size] as? NSNumber,
              size.intValue < 64 else { return }
        try? fm.removeItem(atPath: outputPath)
    }
}
