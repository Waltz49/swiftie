import Foundation

enum AboutBuildInfo {
    private static let excludedDirectoryNames: Set<String> = [
        "venv", "venv_image_browser", "venv_pyinstaller", "__pycache__", "build", "dist",
    ]

    static func packageVersion() -> String {
        if let fromInit = readPackageVersionFromRepo() {
            return fromInit
        }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    static func latestPythonSourceDate(repoRoot: URL?) -> String {
        guard let repoRoot else {
            return formattedNow()
        }
        // Match Python `AboutDialog._find_latest_py_file_date` (scans `browser_window/dialogs/`).
        let scanRoot = repoRoot.appendingPathComponent("browser_window/dialogs", isDirectory: true)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: scanRoot.path),
              let enumerator = fileManager.enumerator(
                  at: scanRoot,
                  includingPropertiesForKeys: [.contentModificationDateKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return formattedNow()
        }

        var latest: Date?
        for case let url as URL in enumerator {
            let components = url.pathComponents
            if components.contains(where: { excludedDirectoryNames.contains($0) }) {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension == "py" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mtime = values.contentModificationDate else { continue }
            if latest == nil || mtime > latest! {
                latest = mtime
            }
        }

        guard let latest else { return formattedNow() }
        return formatted(date: latest)
    }

    static func backgroundJobMode() -> String {
        if let env = ProcessInfo.processInfo.environment["PROWSER_BACKGROUND_JOBS"]?.lowercased() {
            if env == "process" { return "process" }
            if env == "thread" { return "thread" }
        }
        // Match Python `effective_background_job_mode()` (thread when frozen on macOS, else process).
        let isBundledApp = Bundle.main.bundlePath.hasSuffix(".app")
        return isBundledApp ? "thread" : "process"
    }

    static func pythonRuntimeVersion() async -> String {
        guard let repoRoot = PythonLocator.locateRepoRoot(),
              let environment = PythonLocator.resolve(profilePath: nil) else {
            return "Unknown"
        }
        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: environment.executable)
            process.arguments = [
                "-c",
                "import sys; v=sys.version.split()[0]; i=sys.version_info; print(f'{v} ({i.major}.{i.minor}.{i.micro})')",
            ]
            process.currentDirectoryURL = repoRoot
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return text.isEmpty ? "Unknown" : text
            } catch {
                return "Unknown"
            }
        }.value
    }

    private static func readPackageVersionFromRepo() -> String? {
        guard let repoRoot = PythonLocator.locateRepoRoot() else { return nil }
        let initURL = repoRoot.appendingPathComponent("__init__.py")
        guard let text = try? String(contentsOf: initURL, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("__version__") {
                let parts = trimmed.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return parts[1]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return nil
    }

    private static func formattedNow() -> String {
        formatted(date: Date())
    }

    private static func formatted(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
