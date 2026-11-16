import Foundation

/// Creates the profile imagegen venv and installs `requirements-imagegen.txt`.
@MainActor
enum ImageGenVenvInstaller {
    struct InstallResult {
        var success: Bool
        var message: String
    }

    static func install(
        config: AppConfig,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async -> InstallResult {
        let emit: @Sendable (String) -> Void = { chunk in
            onOutput?(chunk)
        }
        let venv = config.imagegenVenvURL()
        let locate = locateSystemPython()
        guard let python = locate.executable else {
            return InstallResult(success: false, message: locate.failureMessage)
        }
        if let existingIssue = unsupportedExistingVenvMessage(venv: venv) {
            return InstallResult(success: false, message: existingIssue)
        }
        guard let requirements = ImageGenVenvPaths.bundledRequirementsURL() else {
            return InstallResult(success: false, message: "Missing requirements-imagegen.txt in app bundle.")
        }
        do {
            try FileManager.default.createDirectory(at: venv.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: config.imagegenVenvPythonPath()) {
                let created = try await run(
                    python,
                    arguments: ["-m", "venv", venv.path],
                    onOutput: emit
                )
                if created.exitCode != 0 {
                    return InstallResult(success: false, message: failureMessage(from: created))
                }
            }
            let venvPython = config.imagegenVenvPythonPath()
            let pip = try await run(
                venvPython,
                arguments: ["-m", "pip", "install", "--upgrade", "pip"],
                onOutput: emit
            )
            if pip.exitCode != 0 {
                return InstallResult(success: false, message: failureMessage(from: pip))
            }
            let install = try await run(
                venvPython,
                arguments: ["-m", "pip", "install", "-r", requirements.path],
                onOutput: emit
            )
            if install.exitCode != 0 {
                return InstallResult(success: false, message: failureMessage(from: install))
            }
            let verify = try await run(
                venvPython,
                arguments: [
                    "-c",
                    "import mflux, diffusers, torch, peft, sdnq; "
                        + "from mflux.utils.image_util import ImageUtil; print('ok')",
                ],
                onOutput: emit
            )
            if verify.exitCode != 0 {
                return InstallResult(
                    success: false,
                    message: "Packages installed but import check failed:\n\(failureMessage(from: verify))"
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

    private static func failureMessage(from result: CommandResult) -> String {
        let combined = result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if combined.isEmpty {
            return "Command failed (exit \(result.exitCode))."
        }
        return combined
    }

    private struct SystemPythonLocate {
        var executable: String?
        var failureMessage: String
    }

    /// Python used to create the profile venv (not the venv interpreter itself).
    private static func locateSystemPython() -> SystemPythonLocate {
        var candidates: [String] = []
        for minor in [13, 12, 11] {
            let ver = "3.\(minor)"
            candidates += [
                "/opt/homebrew/bin/python\(ver)",
                "/usr/local/bin/python\(ver)",
                "/opt/homebrew/opt/python@\(ver)/bin/python\(ver)",
                "/usr/local/opt/python@\(ver)/bin/python\(ver)",
            ]
        }
        candidates += [
            "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        var tooNew: [(path: String, version: PythonVersion)] = []
        var tooOld: [(path: String, version: PythonVersion)] = []
        for path in candidates {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            guard let version = pythonVersion(at: path) else { continue }
            if isSupportedImagegenPython(version) {
                return SystemPythonLocate(executable: path, failureMessage: "")
            }
            if version.major == 3, version.minor >= 14 {
                tooNew.append((path, version))
            } else if version.major == 3, version.minor < 11 {
                tooOld.append((path, version))
            }
        }
        var message =
            "No supported Python found for imagegen. Use Python 3.11, 3.12, or 3.13 "
            + "(not 3.14+: Pillow/mflux break on removed stdlib APIs)."
        if let newest = tooNew.first {
            message += """

            Found Python \(newest.version.major).\(newest.version.minor) at \(newest.path), which is too new.
            On Homebrew, `brew install python` installs 3.14; imagegen needs a versioned formula, e.g.:
              brew install python@3.13
            Then run Install dependencies again (look for /opt/homebrew/bin/python3.13).
            """
        } else if !tooOld.isEmpty {
            message += "\n\nFound only Python 3.10 or older. Install Python 3.12 or 3.13 (e.g. brew install python@3.13)."
        } else {
            message += "\n\nExample: brew install python@3.13"
        }
        return SystemPythonLocate(executable: nil, failureMessage: message)
    }

    private struct PythonVersion {
        var major: Int
        var minor: Int
    }

    private static func isSupportedImagegenPython(_ version: PythonVersion) -> Bool {
        version.major == 3 && version.minor >= 11 && version.minor < 14
    }

    private static func pythonVersion(at executable: String) -> PythonVersion? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = text.split(separator: ".")
        guard parts.count == 2,
              let major = Int(parts[0]),
              let minor = Int(parts[1]) else { return nil }
        return PythonVersion(major: major, minor: minor)
    }

    /// Existing venvs keep their base interpreter; pip alone cannot downgrade Python 3.14 → 3.13.
    private static func unsupportedExistingVenvMessage(venv: URL) -> String? {
        let venvPython = ImageGenVenvPaths.pythonExecutable(in: venv)
        guard FileManager.default.isExecutableFile(atPath: venvPython.path),
              let version = pythonVersion(at: venvPython.path),
              !isSupportedImagegenPython(version) else { return nil }
        return """
        The imagegen venv at \(venv.path) uses Python \(version.major).\(version.minor), which is not supported.

        Remove that folder (or choose a new venv directory in Settings), then run Install dependencies again.
        Python 3.12 or 3.13 will be used automatically.
        """
    }

    private struct CommandResult {
        var exitCode: Int32
        var combinedOutput: String
    }

    private static func commandBanner(executable: String, arguments: [String]) -> String {
        let quotedArgs = arguments.map { arg in
            arg.contains(" ") || arg.contains("\"") ? "\"\(arg.replacingOccurrences(of: "\"", with: "\\\""))\"" : arg
        }
        let line = ([executable] + quotedArgs).joined(separator: " ")
        return "\n=== \(line) ===\n"
    }

    private final class StreamAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var captured = ""
        private let onOutput: @Sendable (String) -> Void

        init(onOutput: @escaping @Sendable (String) -> Void) {
            self.onOutput = onOutput
        }

        func append(_ text: String) {
            guard !text.isEmpty else { return }
            lock.lock()
            captured += text
            lock.unlock()
            onOutput(text)
        }

        var combined: String {
            lock.lock()
            defer { lock.unlock() }
            return captured
        }
    }

    private static func run(
        _ executable: String,
        arguments: [String],
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> CommandResult {
        onOutput(commandBanner(executable: executable, arguments: arguments))
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let accumulator = StreamAccumulator(onOutput: onOutput)

            let stdoutHandle = stdoutPipe.fileHandleForReading
            let stderrHandle = stderrPipe.fileHandleForReading

            stdoutHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let chunk = String(data: data, encoding: .utf8) ?? ""
                accumulator.append(chunk)
            }
            stderrHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let chunk = String(data: data, encoding: .utf8) ?? ""
                accumulator.append(chunk)
            }

            try process.run()
            process.waitUntilExit()

            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil

            let trailingStdout = stdoutHandle.readDataToEndOfFile()
            let trailingStderr = stderrHandle.readDataToEndOfFile()
            if let tail = String(data: trailingStdout, encoding: .utf8) {
                accumulator.append(tail)
            }
            if let tail = String(data: trailingStderr, encoding: .utf8) {
                accumulator.append(tail)
            }

            return CommandResult(exitCode: process.terminationStatus, combinedOutput: accumulator.combined)
        }.value
    }
}
