import Foundation

/// Locates the Python interpreter and repo root for worker subprocesses.
@MainActor
enum PythonLocator {
    struct Environment: Sendable {
        let executable: String
        let repoRoot: URL
        let profilePath: String?
    }

    static func resolve(profilePath: String?, config: AppConfig? = nil) -> Environment? {
        let repoRoot = locateRepoRoot(config: config)
        guard let repoRoot else { return nil }

        let effectiveProfile = resolvedProfilePath(explicit: profilePath, config: config)

        if let executable = locatePythonExecutable(repoRoot: repoRoot, config: config) {
            return Environment(executable: executable, repoRoot: repoRoot, profilePath: effectiveProfile)
        }
        return nil
    }

    /// Python defaults to `~/.prowser` when `PROWSER_PROFILE` is unset; match Swift's active profile.
    static func resolvedProfilePath(explicit: String?, config: AppConfig?) -> String? {
        if let explicit, !explicit.isEmpty {
            return (explicit as NSString).expandingTildeInPath
        }
        if let config {
            return config.prowserHome.path
        }
        return nil
    }

    static func locateRepoRoot(config: AppConfig? = nil) -> URL? {
        if let config,
           let raw = config.rawSettings()["python_root"] as? String,
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL
            if url.appendingPathComponent("prowser.py").exists
                || url.appendingPathComponent("imagegen_plugins").exists {
                return url
            }
        }
        if let env = ProcessInfo.processInfo.environment["PROWSER_PYTHON_ROOT"], !env.isEmpty {
            return URL(fileURLWithPath: env).standardizedFileURL
        }
        if let fromProfile = ProfilePaths.pythonRoot() {
            return fromProfile
        }
        let bundle = Bundle.main.bundleURL
        for candidate in [
            bundle.deletingLastPathComponent().deletingLastPathComponent(),
            bundle.deletingLastPathComponent(),
        ] {
            if candidate.appendingPathComponent("prowser.py").exists {
                return candidate
            }
        }
        return nil
    }

    static func locatePythonExecutable(repoRoot: URL, config: AppConfig? = nil) -> String? {
        if let config,
           let raw = config.rawSettings()["python_executable"] as? String,
           !raw.isEmpty,
           FileManager.default.isExecutableFile(atPath: (raw as NSString).expandingTildeInPath) {
            return (raw as NSString).expandingTildeInPath
        }
        let venvPython = repoRoot
            .appendingPathComponent("venv_image_browser/bin/python")
        if venvPython.exists { return venvPython.path }

        let fallbacks = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        for path in fallbacks where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    static func moduleArguments(_ module: String) -> [String] {
        ["-u", "-m", module]
    }

    /// Kill orphaned worker subprocesses left behind when a prior app instance exited uncleanly.
    static func reapOrphanWorkers(environment: Environment) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: environment.executable)
        process.arguments = [
            "-c",
            "from workers.model_tasks_process_registry import reap_orphan_workers; "
                + "reaped = reap_orphan_workers(); "
                + "print(f'[workers] reaped {len(reaped)} orphan worker(s): {reaped}', flush=True) "
                + "if reaped else None",
        ]
        process.currentDirectoryURL = environment.repoRoot
        var env = ProcessInfo.processInfo.environment
        env["PROWSER_PYTHON_ROOT"] = environment.repoRoot.path
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Best-effort cleanup; worker startup still proceeds if this fails.
        }
    }

    static func prowserWorkerArguments(_ flag: String) -> [String] {
        ["-u", "prowser.py", flag]
    }
}

private extension URL {
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}
