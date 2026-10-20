import Foundation

/// Creates the profile imagegen venv and installs `requirements-imagegen.txt`.
@MainActor
enum ImageGenVenvInstaller {
    struct InstallResult {
        var success: Bool
        var message: String
    }

    static func install(config: AppConfig) async -> InstallResult {
        let venv = config.imagegenVenvURL()
        let python = locateSystemPython()
        guard let python else {
            return InstallResult(success: false, message: "No system python3 found (install Python 3.11+).")
        }
        guard let requirements = ImageGenVenvPaths.bundledRequirementsURL() else {
            return InstallResult(success: false, message: "Missing requirements-imagegen.txt in app bundle.")
        }
        do {
            try FileManager.default.createDirectory(at: venv.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: config.imagegenVenvPythonPath()) {
                let created = try await run(python, arguments: ["-m", "venv", venv.path])
                if created.exitCode != 0 {
                    return InstallResult(success: false, message: created.stderr)
                }
            }
            let venvPython = config.imagegenVenvPythonPath()
            let pip = try await run(venvPython, arguments: ["-m", "pip", "install", "--upgrade", "pip"])
            if pip.exitCode != 0 {
                return InstallResult(success: false, message: pip.stderr)
            }
            let install = try await run(venvPython, arguments: [
                "-m", "pip", "install", "-r", requirements.path,
            ])
            if install.exitCode != 0 {
                return InstallResult(success: false, message: install.stderr)
            }
            let verify = try await run(venvPython, arguments: [
                "-c",
                "import mflux, diffusers, torch, peft, sdnq; print('ok')",
            ])
            if verify.exitCode != 0 {
                return InstallResult(
                    success: false,
                    message: "Packages installed but import check failed:\n\(verify.stderr)"
                )
            }
            return InstallResult(
                success: true,
                message:
                    "Imagegen venv ready at \(venv.path). "
                    + "Optimized generation uses this environment (mflux, diffusers, peft, sdnq). "
                    + "Download model weights from Image → Manage models… when needed."
            )
        } catch {
            return InstallResult(success: false, message: error.localizedDescription)
        }
    }

    private static func locateSystemPython() -> String? {
        for path in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private struct CommandResult {
        var exitCode: Int32
        var stderr: String
    }

    private static func run(_ executable: String, arguments: [String]) async throws -> CommandResult {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            try process.run()
            // Drain stderr before waiting: pip can fill the pipe buffer and block otherwise.
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let err = String(data: errData, encoding: .utf8) ?? ""
            return CommandResult(exitCode: process.terminationStatus, stderr: err)
        }.value
    }
}
