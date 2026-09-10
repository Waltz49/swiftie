import Foundation

/// Locates the Python interpreter and repo root for worker subprocesses.
enum PythonLocator {
    struct Environment: Sendable {
        let executable: String
        let repoRoot: URL
    }

    static func resolve(profilePath: String?) -> Environment? {
        let repoRoot = locateRepoRoot()
        guard let repoRoot else { return nil }

        if let executable = locatePythonExecutable(repoRoot: repoRoot) {
            return Environment(executable: executable, repoRoot: repoRoot)
        }
        return nil
    }

    static func locateRepoRoot() -> URL? {
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

    static func locatePythonExecutable(repoRoot: URL) -> String? {
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

    static func prowserWorkerArguments(_ flag: String) -> [String] {
        ["-u", "prowser.py", flag]
    }
}

private extension URL {
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}
