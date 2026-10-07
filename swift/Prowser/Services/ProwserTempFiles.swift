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

    static func imageGenProgressDirectory(prowserHome: URL? = nil) -> String {
        let home = prowserHome ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(ProfilePaths.defaultProfileDirectoryName, isDirectory: true)
        let dir = home.appendingPathComponent("tmp/imagegen-progress", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private static let legacyProgressPrefix = ".imagegen-progress-"

    /// Remove ``{profile}/tmp/imagegen-progress`` on shutdown (debug off), matching profile tmp cleanup.
    static func cleanupImageGenProgressDirectoryOnShutdown(debugMode: Bool) {
        guard !debugMode else { return }
        let dir = imageGenProgressDirectory()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return }
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// Port of ``prowser_temp_files.cleanup_stale_imagegen_worker_temps`` (orphaned files in profile tmp).
    static func cleanupStaleImageGenWorkerTemps(debugMode: Bool) {
        guard !debugMode else { return }
        let tmpDir = (imageGenProgressDirectory() as NSString).deletingLastPathComponent
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
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: tmpDir) else { return }
        for name in names {
            let full = (tmpDir as NSString).appendingPathComponent(name)
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
