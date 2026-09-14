import Foundation

/// Paths under a Prowser profile root (default `~/.swift-prowser`).
struct ProfilePaths: Sendable {
    static let defaultProfileDirectoryName = ".swift-prowser"

    let prowserHome: URL

    init(profilePath: String?) {
        if let profilePath, !profilePath.isEmpty {
            prowserHome = URL(fileURLWithPath: (profilePath as NSString).expandingTildeInPath)
                .standardizedFileURL
        } else {
            prowserHome = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(Self.defaultProfileDirectoryName, isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: prowserHome, withIntermediateDirectories: true)
    }

    var dataDirectory: URL {
        let url = prowserHome.appendingPathComponent("data", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var settingsFile: URL { dataDirectory.appendingPathComponent("settings.json") }
    var instanceLockFile: URL { dataDirectory.appendingPathComponent("instance.lock") }

    var cacheDirectory: URL {
        let url = prowserHome.appendingPathComponent("cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var imageCacheDirectory: URL {
        let url = cacheDirectory.appendingPathComponent("image_browser_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var thumbnailCacheDirectory: URL {
        let url = imageCacheDirectory.appendingPathComponent("thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var metadataCacheDirectory: URL {
        let url = imageCacheDirectory.appendingPathComponent("metadata", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var imageRecognitionCacheDirectory: URL {
        let url = cacheDirectory.appendingPathComponent("image_recognition", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var temporaryFilesDirectory: URL {
        // Default-only; prefer ``AppConfig/temporaryFilesDirectory`` for settings-aware path.
        let url = prowserHome.appendingPathComponent("tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var logsDirectory: URL {
        let url = prowserHome.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var namedPipePath: String {
        let user = NSUserName()
        return "/tmp/image_browser_pipe_\(user)"
    }

    /// Repo-root venv or bundled Python for worker subprocesses (Milestone 6).
    static func pythonRoot() -> URL? {
        if let env = ProcessInfo.processInfo.environment["PROWSER_PYTHON_ROOT"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        let cwd = FileManager.default.currentDirectoryPath
        let candidate = URL(fileURLWithPath: cwd)
        if candidate.appendingPathComponent("prowser.py").exists {
            return candidate
        }
        let parent = candidate.deletingLastPathComponent()
        if parent.appendingPathComponent("prowser.py").exists {
            return parent
        }
        return nil
    }
}

private extension URL {
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}
