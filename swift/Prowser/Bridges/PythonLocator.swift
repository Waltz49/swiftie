import Foundation

/// Locates system Python and the vendored ImageGenPython bundle for worker subprocesses.
@MainActor
enum PythonLocator {
    struct Environment: Sendable {
        let executable: String
        /// Vendored bundle root (`ImageGenPython` on `PYTHONPATH`).
        let bundleRoot: URL
        let profilePath: String?
    }

    static func resolve(profilePath: String?, config: AppConfig? = nil) -> Environment? {
        guard let bundleRoot = ImageGenPythonBundle.rootURL() else { return nil }
        let effectiveProfile = resolvedProfilePath(explicit: profilePath, config: config)
        guard let executable = locatePythonExecutable(config: config) else { return nil }
        return Environment(executable: executable, bundleRoot: bundleRoot, profilePath: effectiveProfile)
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

    static func locatePythonExecutable(config: AppConfig? = nil) -> String? {
        if let config,
           let raw = config.rawSettings()["python_executable"] as? String,
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let path = (raw as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        if let config {
            let venvPython = config.imagegenVenvPythonPath()
            if FileManager.default.isExecutableFile(atPath: venvPython) {
                return venvPython
            }
        }
        let fallbacks = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        for path in fallbacks where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    static func moduleArguments(_ module: String) -> [String] {
        ["-u", "-m", module]
    }

    nonisolated static func processEnvironment(
        for environment: Environment,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        ImageGenPythonBundle.applyPythonEnvironment(
            &env,
            bundleRoot: environment.bundleRoot,
            profilePath: environment.profilePath
        )
        for (key, value) in extra {
            env[key] = value
        }
        return env
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
        process.currentDirectoryURL = environment.bundleRoot
        process.environment = processEnvironment(for: environment)
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Best-effort cleanup; worker startup still proceeds if this fails.
        }
    }
}
